package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestDecisionFollowsTheDeclaration(t *testing.T) {
	cfg, err := Parse([]byte(authTestConfig))
	if err != nil {
		t.Fatal(err)
	}
	decide := decisionFunc(func() *Config { return cfg })

	for name, allowed := range map[string]bool{
		"sd-webui.poissonnerie.dev": true,
		"docs.poissonnerie.dev":     true,
		"auth.poissonnerie.dev":     true,
		"nope.poissonnerie.dev":     false,
		"poissonnerie.dev":          false,
		"sd-webui.oeilvert.dev":     false,
		"":                          false,
	} {
		t.Run(name, func(t *testing.T) {
			err := decide(context.Background(), name)
			if allowed && err != nil {
				t.Errorf("refused a declared name: %v", err)
			}
			if !allowed && err == nil {
				t.Error("agreed to ask Let's Encrypt for an undeclared name")
			}
		})
	}
}

// Before the first configuration is in force, nothing is worth a certificate.
func TestDecisionRefusesWithoutAConfig(t *testing.T) {
	decide := decisionFunc(func() *Config { return nil })
	if err := decide(context.Background(), "sd-webui.poissonnerie.dev"); err == nil {
		t.Error("it agreed to obtain a certificate with no configuration loaded")
	}
}

func TestRenewalLogRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "renewal.json")
	l := &RenewalLog{path: path}

	when := epoch
	if err := l.Record(Renewal{Host: "sd-webui.poissonnerie.dev", At: when, OK: true}); err != nil {
		t.Fatalf("Record: %v", err)
	}
	if err := l.Record(Renewal{Host: "docs.poissonnerie.dev", At: when, OK: false, Problem: "boom"}); err != nil {
		t.Fatalf("Record: %v", err)
	}

	all, err := l.All()
	if err != nil {
		t.Fatalf("All: %v", err)
	}
	if len(all) != 2 {
		t.Fatalf("got %d records, want 2", len(all))
	}
	if r := all["docs.poissonnerie.dev"]; r.OK || r.Problem != "boom" {
		t.Errorf("docs record = %+v", r)
	}
	if r := all["sd-webui.poissonnerie.dev"]; !r.OK {
		t.Errorf("sd-webui record = %+v", r)
	}
}

func TestRenewalLogKeepsOnlyTheLatestPerHost(t *testing.T) {
	path := filepath.Join(t.TempDir(), "renewal.json")
	l := &RenewalLog{path: path}
	l.Record(Renewal{Host: "a.z.dev", At: epoch, OK: false, Problem: "first"})
	l.Record(Renewal{Host: "a.z.dev", At: epoch.Add(time.Hour), OK: true})

	all, _ := l.All()
	if len(all) != 1 {
		t.Fatalf("got %d records, want 1", len(all))
	}
	if r := all["a.z.dev"]; !r.OK || r.Problem != "" {
		t.Errorf("record = %+v, want the later success", r)
	}
}

// status has to work when nothing has been recorded yet, and must not be taken
// down by a truncated file.
func TestRenewalLogSurvivesNothingAndNonsense(t *testing.T) {
	dir := t.TempDir()

	l := &RenewalLog{path: filepath.Join(dir, "absent.json")}
	all, err := l.All()
	if err != nil {
		t.Errorf("All on a missing file: %v", err)
	}
	if len(all) != 0 {
		t.Errorf("got %d records from nothing", len(all))
	}

	broken := filepath.Join(dir, "broken.json")
	os.WriteFile(broken, []byte("{not json"), 0o600)
	l = &RenewalLog{path: broken}
	if _, err := l.All(); err == nil {
		t.Error("a corrupt file was read as valid")
	}
}

func TestRenewalLogIsWrittenPrivately(t *testing.T) {
	path := filepath.Join(t.TempDir(), "renewal.json")
	l := &RenewalLog{path: path}
	l.Record(Renewal{Host: "a.z.dev", At: epoch, OK: true})

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		t.Errorf("mode = %o, want no group or other bits", perm)
	}
}

func TestCertificateExpiry(t *testing.T) {
	dir := t.TempDir()
	notAfter := epoch.Add(90 * 24 * time.Hour)
	// certmagic files certificates under an issuer directory; the reader has
	// to find one without being told which.
	certDir := filepath.Join(dir, "certificates", "acme-v02.api.letsencrypt.org-directory", "sd-webui.poissonnerie.dev")
	if err := os.MkdirAll(certDir, 0o700); err != nil {
		t.Fatal(err)
	}
	writeTestCert(t, filepath.Join(certDir, "sd-webui.poissonnerie.dev.crt"), "sd-webui.poissonnerie.dev", notAfter)

	got, err := CertificateExpiry(dir, "sd-webui.poissonnerie.dev")
	if err != nil {
		t.Fatalf("CertificateExpiry: %v", err)
	}
	if !got.Equal(notAfter.Truncate(time.Second)) {
		t.Errorf("expiry = %v, want %v", got, notAfter)
	}
}

func TestCertificateExpiryWhenThereIsNone(t *testing.T) {
	if _, err := CertificateExpiry(t.TempDir(), "sd-webui.poissonnerie.dev"); err == nil {
		t.Error("it reported an expiry for a certificate that does not exist")
	}
}

func writeTestCert(t *testing.T, path, name string, notAfter time.Time) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: name},
		DNSNames:     []string{name},
		NotBefore:    notAfter.Add(-90 * 24 * time.Hour),
		NotAfter:     notAfter,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := pem.Encode(f, &pem.Block{Type: "CERTIFICATE", Bytes: der}); err != nil {
		t.Fatal(err)
	}
}

// docs/adr/0006 wants every declared name under the renewal loop's eye, not
// only the ones somebody has visited. certmagic's ManageAsync does not do that
// when on-demand is configured -- it files the name in an allow-list and
// returns -- so CertManager primes the cache itself, and this is the check that
// it covers everything the declaration names.
func TestManageCoversEveryDeclaredName(t *testing.T) {
	cfg, err := Parse([]byte(authTestConfig))
	if err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	primed := map[string]int{}
	m := NewCertManager(t.TempDir(), func() *Config { return cfg }, "https://example.invalid/directory")
	m.primeOne = func(_ context.Context, name string) {
		mu.Lock()
		defer mu.Unlock()
		primed[name]++
	}

	if err := m.Manage(context.Background(), cfg.Hostnames()); err != nil {
		t.Fatalf("Manage: %v", err)
	}
	m.waitForPriming()

	mu.Lock()
	defer mu.Unlock()
	for _, want := range cfg.Hostnames() {
		if primed[want] == 0 {
			t.Errorf("%s was never primed", want)
		}
	}
	if len(primed) != len(cfg.Hostnames()) {
		t.Errorf("primed %v, want exactly %v", primed, cfg.Hostnames())
	}
}

// The auth host is in Hostnames() even with nothing published, so it is primed
// too -- without a certificate there, nobody can log in to anything.
func TestManageCoversTheAuthHostWithNoServices(t *testing.T) {
	cfg, err := Parse([]byte("zone: z.dev\nservices: []\n"))
	if err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	var primed []string
	m := NewCertManager(t.TempDir(), func() *Config { return cfg }, "https://example.invalid/directory")
	m.primeOne = func(_ context.Context, name string) {
		mu.Lock()
		defer mu.Unlock()
		primed = append(primed, name)
	}

	if err := m.Manage(context.Background(), cfg.Hostnames()); err != nil {
		t.Fatalf("Manage: %v", err)
	}
	m.waitForPriming()

	mu.Lock()
	defer mu.Unlock()
	if len(primed) != 1 || primed[0] != "auth.z.dev" {
		t.Errorf("primed %v, want [auth.z.dev]", primed)
	}
}
