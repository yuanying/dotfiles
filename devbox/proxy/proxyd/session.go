package main

// Signed tokens, and the key that signs them.
//
// docs/adr/0007 chose a self-contained cookie over a session store: the process
// keeps no state, a restart does not log anybody out, and the only revocation
// is rotating the key. Two things follow, and both are enforced here. The
// service name goes inside the signature, so a cookie for a service anyone may
// read cannot open one that asks for a login. And the kind goes in too, so the
// thirty-second token that carries a visitor from the auth host to a service
// cannot be kept and used as a session.

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// TokenKind separates the two things a signature is used for. They are kept
// deliberately short: this travels in a cookie on every request.
type TokenKind string

const (
	// KindCookie is a session at one service host.
	KindCookie TokenKind = "c"
	// KindHandover carries an identity from the auth host to a service host,
	// once, within seconds.
	KindHandover TokenKind = "h"
	// KindState is the OAuth state parameter: it remembers where the visitor
	// was going while they are away at GitHub.
	KindState TokenKind = "s"
	// KindAPI is a bearer token for a client that is not a browser. It is
	// signed with a different key from the other three (docs/adr/0010).
	KindAPI TokenKind = "a"
)

// keySize is what a fresh key gets, and the minimum an existing one may be.
const keySize = 32

// Token is what a signature attests to.
type Token struct {
	Kind    TokenKind
	Subject string // the GitHub account name
	Service string
	Path    string    // where to continue; handover only
	Expires time.Time // zero means it never expires; API tokens only
}

type payload struct {
	Kind    TokenKind `json:"k"`
	Subject string    `json:"sub"`
	Service string    `json:"svc"`
	Path    string    `json:"p,omitempty"`
	Expires int64     `json:"exp"`
}

// Signer issues and verifies tokens.
type Signer struct {
	key []byte
	now func() time.Time
}

// NewSigner returns a Signer over key.
func NewSigner(key []byte) *Signer {
	return &Signer{key: key, now: time.Now}
}

// Issue signs a token.
func (s *Signer) Issue(t Token) (string, error) {
	if t.Kind != KindCookie && t.Kind != KindHandover && t.Kind != KindAPI {
		return "", fmt.Errorf("unknown token kind %q", t.Kind)
	}
	if t.Subject == "" || t.Service == "" {
		return "", errors.New("a token needs both a subject and a service")
	}
	if t.Kind == KindHandover {
		if err := checkPath(t.Path); err != nil {
			return "", err
		}
	}
	// A session that never ends is a bug; an API token that never ends is a
	// choice somebody made at the command line (docs/adr/0010).
	if t.Expires.IsZero() && t.Kind != KindAPI {
		return "", fmt.Errorf("a %q must say when it expires", t.Kind)
	}

	return s.issue(payload{
		Kind:    t.Kind,
		Subject: t.Subject,
		Service: t.Service,
		Path:    t.Path,
		Expires: expiryOf(t.Expires),
	})
}

// expiryOf encodes the expiry, using zero for "never". time.Time's own zero
// value is far in the past, so it cannot be handed to Unix() unexamined.
func expiryOf(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.Unix()
}

func (s *Signer) issue(p payload) (string, error) {
	body, err := json.Marshal(p)
	if err != nil {
		return "", err
	}
	encoded := base64.RawURLEncoding.EncodeToString(body)
	return encoded + "." + s.sign(encoded), nil
}

// Verify checks a token's signature, its kind, the service it was issued for
// and its expiry, in that order -- nothing is parsed as JSON until the
// signature has been shown to hold.
func (s *Signer) Verify(raw string, kind TokenKind, service string) (*Token, error) {
	p, err := s.parse(raw, kind)
	if err != nil {
		return nil, err
	}
	if p.Service != service {
		return nil, fmt.Errorf("token was issued for %q, not %q", p.Service, service)
	}
	var expires time.Time
	if p.Expires != 0 {
		expires = time.Unix(p.Expires, 0)
	}
	return &Token{
		Kind:    p.Kind,
		Subject: p.Subject,
		Service: p.Service,
		Path:    p.Path,
		Expires: expires,
	}, nil
}

// IssueState signs the OAuth state parameter. It carries where the visitor was
// going, so that the callback -- which GitHub reaches with nothing but a code
// and this string -- knows where to send them next. The nonce is matched
// against a cookie on the auth host, so a state parameter somebody else
// obtained cannot be used to start a login in this browser.
func (s *Signer) IssueState(nonce, service, path string, expires time.Time) (string, error) {
	if err := checkPath(path); err != nil {
		return "", err
	}
	if expires.IsZero() {
		return "", errors.New("a state parameter must say when it expires")
	}
	return s.issue(payload{
		Kind:    KindState,
		Subject: nonce,
		Service: service,
		Path:    path,
		Expires: expires.Unix(),
	})
}

// VerifyState checks a state parameter and returns what it was carrying.
func (s *Signer) VerifyState(raw string) (nonce, service, path string, err error) {
	p, err := s.parse(raw, KindState)
	if err != nil {
		return "", "", "", err
	}
	return p.Subject, p.Service, p.Path, nil
}

// parse checks the signature before anything else is believed, then the kind
// and the expiry.
func (s *Signer) parse(raw string, kind TokenKind) (*payload, error) {
	parts := strings.Split(raw, ".")
	if len(parts) != 2 {
		return nil, errors.New("malformed token")
	}
	encoded, sig := parts[0], parts[1]

	if !hmac.Equal([]byte(sig), []byte(s.sign(encoded))) {
		return nil, errors.New("bad signature")
	}

	body, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		return nil, errors.New("malformed token")
	}
	var p payload
	if err := json.Unmarshal(body, &p); err != nil {
		return nil, errors.New("malformed token")
	}

	if p.Kind != kind {
		return nil, fmt.Errorf("token is a %q, not a %q", p.Kind, kind)
	}
	if p.Expires != 0 && s.now().After(time.Unix(p.Expires, 0)) {
		return nil, errors.New("token has expired")
	}
	return &p, nil
}

func (s *Signer) sign(encoded string) string {
	mac := hmac.New(sha256.New, s.key)
	mac.Write([]byte(encoded))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// checkPath keeps a handover from being turned into an open redirect. Only a
// path within the service host is allowed: "//host" and "https://host" both
// leave the site, and a relative path is ambiguous.
func checkPath(p string) error {
	if !strings.HasPrefix(p, "/") || strings.HasPrefix(p, "//") {
		return fmt.Errorf("%q is not a path on this host", p)
	}
	return nil
}

// LoadOrCreateKey reads the signing key, generating one if there is none.
//
// docs/adr/0007: a secret that can be generated is generated, so a first start
// needs no preparation. The GitHub client secret is the other half of that
// decision -- GitHub issues it, so it has to be placed by hand.
func LoadOrCreateKey(path string) ([]byte, error) {
	key, err := readKey(path)
	switch {
	case err == nil:
		return key, nil
	case !errors.Is(err, os.ErrNotExist):
		return nil, err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	fresh := make([]byte, keySize)
	if _, err := rand.Read(fresh); err != nil {
		return nil, err
	}

	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, os.ErrExist) {
		// Another process got there first; read what it wrote rather than
		// racing it, so the two do not end up signing with different keys.
		return readKey(path)
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if _, err := f.Write(fresh); err != nil {
		return nil, err
	}
	return fresh, f.Close()
}

func readKey(path string) ([]byte, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if info.Mode().Perm()&0o077 != 0 {
		return nil, fmt.Errorf("%s is readable by other accounts (mode %o); chmod 600 it", path, info.Mode().Perm())
	}
	key, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(key) < keySize {
		return nil, fmt.Errorf("%s is %d bytes; a signing key is at least %d", path, len(key), keySize)
	}
	return key, nil
}
