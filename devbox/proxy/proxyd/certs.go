package main

// Certificates: obtaining them, renewing them, and being able to say what
// happened.
//
// docs/adr/0006 takes them from Let's Encrypt over HTTP-01, one per published
// name, so that nothing here needs a Cloudflare API token -- a wildcard
// certificate would have to write DNS records every ninety days, which is the
// resident credential 0002 argued against.
//
// Two mechanisms run together. Every declared name is registered for management
// at startup, asynchronously, so the renewal loop watches names nobody has
// visited; and the on-demand decision function covers names added by a reload
// since. Without the first, a service nobody opens for ninety days expires
// quietly. Without the second, startup would have to wait for the network.

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/caddyserver/certmagic"
)

// CertManager owns the TLS side.
type CertManager struct {
	magic   *certmagic.Config
	issuer  *certmagic.ACMEIssuer
	storage string

	// Log is what `status` reads to answer "did the last renewal fail?".
	Log *RenewalLog

	// primeOne is what Manage does to each name, overridable so the tests can
	// watch which names are covered without talking to an ACME server.
	primeOne func(ctx context.Context, name string)
	priming  sync.WaitGroup
}

// NewCertManager wires certmagic against the state directory. acmeCA is the
// ACME directory URL; the staging one is how a change is verified without
// spending the production rate limit (docs/adr/0006).
func NewCertManager(stateDir string, current func() *Config, acmeCA string) *CertManager {
	storagePath := filepath.Join(stateDir, "certs")
	m := &CertManager{
		storage: storagePath,
		Log:     &RenewalLog{path: filepath.Join(stateDir, "renewal.json")},
	}

	var magic *certmagic.Config
	cache := certmagic.NewCache(certmagic.CacheOptions{
		GetConfigForCert: func(certmagic.Certificate) (*certmagic.Config, error) {
			return magic, nil
		},
	})
	magic = certmagic.New(cache, certmagic.Config{
		Storage: &certmagic.FileStorage{Path: storagePath},
		OnDemand: &certmagic.OnDemandConfig{
			DecisionFunc: decisionFunc(current),
		},
		OnEvent: m.record,
	})

	issuer := certmagic.NewACMEIssuer(magic, certmagic.ACMEIssuer{
		CA:     acmeCA,
		Agreed: true,
	})
	magic.Issuers = []certmagic.Issuer{issuer}

	m.magic = magic
	m.issuer = issuer
	m.primeOne = m.prime
	return m
}

// Manage puts names under management. It does not block on the network: a
// devbox that reboots with no uplink still starts and serves what it can.
//
// ManageAsync alone is not enough. With an OnDemandConfig set -- which is what
// keeps a stranger's request for xyz.<zone> from costing a certificate --
// certmagic's manageAll files each name in an on-demand allow-list and returns
// without obtaining or caching anything. The renewal loop only ever looks at
// certificates in the cache, so names nobody has visited would never be
// renewed, which is precisely what docs/adr/0006 registers them to avoid. So
// the allow-list registration is kept for its own sake, and the caching is
// done here.
func (m *CertManager) Manage(ctx context.Context, names []string) error {
	if err := m.magic.ManageAsync(ctx, names); err != nil {
		return err
	}
	for _, name := range names {
		m.priming.Add(1)
		go func(name string) {
			defer m.priming.Done()
			m.primeOne(ctx, name)
		}(name)
	}
	return nil
}

// waitForPriming blocks until every name Manage started has been dealt with.
// Only the tests need this; serving does not wait for it.
func (m *CertManager) waitForPriming() { m.priming.Wait() }

// prime puts one name's certificate in the cache, obtaining it first if there
// is none, so that the renewal loop can see it. This is what manageOne does
// internally when on-demand is not in the way.
//
// A failure here is not fatal and is not retried: the on-demand path still
// covers the name at the next handshake, and a certificate that was obtained
// once is on disk, where the next start finds it. What is lost is the
// background renewal of a name that has never had a certificate at all, and
// `status` reports that as pending rather than as working.
func (m *CertManager) prime(ctx context.Context, name string) {
	if _, err := m.magic.CacheManagedCertificate(ctx, name); err == nil {
		return
	} else if !errors.Is(err, fs.ErrNotExist) {
		log.Printf("certificates: caching %s: %v", name, err)
		return
	}

	if err := m.magic.ObtainCertAsync(ctx, name); err != nil {
		log.Printf("certificates: obtaining one for %s: %v", name, err)
		return
	}
	if _, err := m.magic.CacheManagedCertificate(ctx, name); err != nil {
		log.Printf("certificates: caching %s after obtaining it: %v", name, err)
	}
}

// TLSConfig is what the HTTPS listener runs on.
func (m *CertManager) TLSConfig() *tls.Config {
	tc := m.magic.TLSConfig()
	// certmagic sets only the ACME protocol; the listener also has to speak
	// to browsers.
	tc.NextProtos = append([]string{"h2", "http/1.1"}, tc.NextProtos...)
	return tc
}

// ChallengeHandler answers ACME HTTP-01 on port 80 and passes everything else
// to next, which redirects to HTTPS.
func (m *CertManager) ChallengeHandler(next http.Handler) http.Handler {
	return m.issuer.HTTPChallengeHandler(next)
}

// StoragePath is where certificates live, for `status` to read without the
// process running.
func (m *CertManager) StoragePath() string { return m.storage }

// record turns certmagic's events into something status can print. It never
// returns an error: failing to write a note is not a reason to abandon a
// renewal.
func (m *CertManager) record(ctx context.Context, event string, data map[string]any) error {
	name, _ := data["identifier"].(string)
	if name == "" {
		return nil
	}
	switch event {
	case "cert_obtained":
		m.Log.Record(Renewal{Host: name, At: time.Now(), OK: true})
	case "cert_failed":
		problem := "unknown"
		if err, ok := data["error"].(error); ok && err != nil {
			problem = err.Error()
		}
		m.Log.Record(Renewal{Host: name, At: time.Now(), OK: false, Problem: problem})
	}
	return nil
}

// decisionFunc is the allow-list certmagic consults before talking to
// Let's Encrypt. The wildcard AAAA record means any label in the zone arrives
// here, so without this a stranger asking for xyz.<zone> would have us request
// a certificate we do not want, over and over.
func decisionFunc(current func() *Config) func(context.Context, string) error {
	return func(_ context.Context, name string) error {
		cfg := current()
		if cfg == nil {
			return errors.New("no declaration is in force yet")
		}
		if !cfg.Allows(name) {
			return fmt.Errorf("%s is not published from this devbox", name)
		}
		return nil
	}
}

// Renewal is the outcome of one attempt at one name.
type Renewal struct {
	Host    string    `json:"host"`
	At      time.Time `json:"at"`
	OK      bool      `json:"ok"`
	Problem string    `json:"problem,omitempty"`
}

// RenewalLog is the last outcome per name, on disk.
//
// docs/adr/0008 keeps every channel between the process and the shell on the
// filesystem, so that `status` can answer while the process is stopped -- which
// is exactly when "when does this expire, and did the last renewal fail?" is
// most worth asking.
type RenewalLog struct {
	path string
	mu   sync.Mutex
}

// Record stores the outcome for one host, replacing any earlier one.
func (l *RenewalLog) Record(r Renewal) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	all, err := l.read()
	if err != nil {
		// A file we cannot read is replaced rather than preserved: losing old
		// notes matters less than losing the ability to take new ones.
		all = map[string]Renewal{}
	}
	all[r.Host] = r

	data, err := json.MarshalIndent(all, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(l.path), 0o700); err != nil {
		return err
	}
	tmp := l.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, l.path)
}

// All is every recorded outcome, keyed by host.
func (l *RenewalLog) All() (map[string]Renewal, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.read()
}

func (l *RenewalLog) read() (map[string]Renewal, error) {
	data, err := os.ReadFile(l.path)
	if errors.Is(err, os.ErrNotExist) {
		// Nothing has been attempted yet. Not a problem to report.
		return map[string]Renewal{}, nil
	}
	if err != nil {
		return nil, err
	}
	all := map[string]Renewal{}
	if err := json.Unmarshal(data, &all); err != nil {
		return nil, fmt.Errorf("%s: %w", l.path, err)
	}
	return all, nil
}

// CertificateExpiry reads the certificate for host out of certmagic's storage
// without needing the process to be running. Certificates from more than one
// issuer can be on disk at once -- switching between the staging and production
// directories leaves both -- so the one that lasts longest is the answer.
func CertificateExpiry(storagePath, host string) (time.Time, error) {
	root := filepath.Join(storagePath, "certificates")
	want := host + ".crt"

	var latest time.Time
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.EqualFold(d.Name(), want) {
			return nil
		}
		notAfter, err := certNotAfter(path)
		if err != nil {
			return nil
		}
		if notAfter.After(latest) {
			latest = notAfter
		}
		return nil
	})
	if err != nil {
		return time.Time{}, err
	}
	if latest.IsZero() {
		return time.Time{}, fmt.Errorf("no certificate for %s in %s", host, storagePath)
	}
	return latest, nil
}

func certNotAfter(path string) (time.Time, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return time.Time{}, err
	}
	for {
		block, rest := pem.Decode(data)
		if block == nil {
			return time.Time{}, fmt.Errorf("%s holds no certificate", path)
		}
		if block.Type == "CERTIFICATE" {
			cert, err := x509.ParseCertificate(block.Bytes)
			if err != nil {
				return time.Time{}, err
			}
			return cert.NotAfter, nil
		}
		data = rest
	}
}
