package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testSigner(t *testing.T, now time.Time) *Signer {
	t.Helper()
	s := NewSigner([]byte("0123456789abcdef0123456789abcdef"))
	s.now = func() time.Time { return now }
	return s
}

var epoch = time.Date(2026, 8, 20, 12, 0, 0, 0, time.UTC)

func TestCookieRoundTrip(t *testing.T) {
	s := testSigner(t, epoch)
	raw, err := s.Issue(Token{
		Kind:    KindCookie,
		Subject: "yuanying",
		Service: "sd-webui",
		Expires: epoch.Add(time.Hour),
	})
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	tok, err := s.Verify(raw, KindCookie, "sd-webui")
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if tok.Subject != "yuanying" {
		t.Errorf("Subject = %q, want yuanying", tok.Subject)
	}
	if tok.Service != "sd-webui" {
		t.Errorf("Service = %q, want sd-webui", tok.Service)
	}
}

func TestHandoverCarriesThePath(t *testing.T) {
	s := testSigner(t, epoch)
	raw, err := s.Issue(Token{
		Kind:    KindHandover,
		Subject: "yuanying",
		Service: "sd-webui",
		Path:    "/generate?x=1",
		Expires: epoch.Add(30 * time.Second),
	})
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	tok, err := s.Verify(raw, KindHandover, "sd-webui")
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if tok.Path != "/generate?x=1" {
		t.Errorf("Path = %q", tok.Path)
	}
}

// The whole point of putting the service name inside the signature: a cookie
// for a service anyone may read must not open one that asks for a login.
func TestTokenIsBoundToItsService(t *testing.T) {
	s := testSigner(t, epoch)
	raw, _ := s.Issue(Token{
		Kind:    KindCookie,
		Subject: "yuanying",
		Service: "docs",
		Expires: epoch.Add(time.Hour),
	})
	if _, err := s.Verify(raw, KindCookie, "sd-webui"); err == nil {
		t.Fatal("a cookie for docs was accepted for sd-webui")
	}
}

// A handover token is meant to be spent once, immediately, at the service host.
// It must not work as a session cookie, or its short life means nothing.
func TestKindsDoNotSubstitute(t *testing.T) {
	s := testSigner(t, epoch)
	handover, _ := s.Issue(Token{
		Kind:    KindHandover,
		Subject: "yuanying",
		Service: "sd-webui",
		Path:    "/",
		Expires: epoch.Add(30 * time.Second),
	})
	if _, err := s.Verify(handover, KindCookie, "sd-webui"); err == nil {
		t.Fatal("a handover token was accepted as a cookie")
	}

	cookie, _ := s.Issue(Token{
		Kind:    KindCookie,
		Subject: "yuanying",
		Service: "sd-webui",
		Expires: epoch.Add(time.Hour),
	})
	if _, err := s.Verify(cookie, KindHandover, "sd-webui"); err == nil {
		t.Fatal("a cookie was accepted as a handover token")
	}
}

func TestExpiredTokenIsRefused(t *testing.T) {
	s := testSigner(t, epoch)
	raw, _ := s.Issue(Token{
		Kind:    KindCookie,
		Subject: "yuanying",
		Service: "sd-webui",
		Expires: epoch.Add(time.Hour),
	})

	s.now = func() time.Time { return epoch.Add(time.Hour + time.Second) }
	if _, err := s.Verify(raw, KindCookie, "sd-webui"); err == nil {
		t.Fatal("an expired token was accepted")
	}

	// Still good one second before it lapses.
	s.now = func() time.Time { return epoch.Add(time.Hour - time.Second) }
	if _, err := s.Verify(raw, KindCookie, "sd-webui"); err != nil {
		t.Fatalf("a live token was refused: %v", err)
	}
}

func TestTamperingIsRefused(t *testing.T) {
	s := testSigner(t, epoch)
	raw, _ := s.Issue(Token{
		Kind:    KindCookie,
		Subject: "yuanying",
		Service: "sd-webui",
		Expires: epoch.Add(time.Hour),
	})
	dot := strings.IndexByte(raw, '.')
	if dot < 0 {
		t.Fatalf("token %q has no separator", raw)
	}
	payload, sig := raw[:dot], raw[dot+1:]

	for _, tc := range []struct{ name, token string }{
		{"a flipped payload byte", flip(payload) + "." + sig},
		{"a flipped signature byte", payload + "." + flip(sig)},
		{"no signature", payload},
		{"an empty signature", payload + "."},
		{"an empty payload", "." + sig},
		{"nothing at all", ""},
		{"only a separator", "."},
		{"payload that is not base64", "!!!!." + sig},
		{"a second separator", payload + "." + sig + ".extra"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := s.Verify(tc.token, KindCookie, "sd-webui"); err == nil {
				t.Errorf("Verify accepted %q", tc.token)
			}
		})
	}
}

// Rotating the key is the only revocation there is (docs/adr/0007), so it has
// to actually invalidate what the old key signed.
func TestAnotherKeyCannotVerify(t *testing.T) {
	issuer := testSigner(t, epoch)
	raw, _ := issuer.Issue(Token{
		Kind:    KindCookie,
		Subject: "yuanying",
		Service: "sd-webui",
		Expires: epoch.Add(time.Hour),
	})

	other := NewSigner([]byte("fedcba9876543210fedcba9876543210"))
	other.now = func() time.Time { return epoch }
	if _, err := other.Verify(raw, KindCookie, "sd-webui"); err == nil {
		t.Fatal("a token signed with another key verified")
	}
}

func TestIssueRejectsAnUnsafePath(t *testing.T) {
	s := testSigner(t, epoch)
	for _, path := range []string{
		"//evil.example.com/", // protocol-relative: leaves the site
		"https://evil.example.com/",
		"not-absolute",
	} {
		t.Run(path, func(t *testing.T) {
			if _, err := s.Issue(Token{
				Kind:    KindHandover,
				Subject: "yuanying",
				Service: "sd-webui",
				Path:    path,
				Expires: epoch.Add(time.Minute),
			}); err == nil {
				t.Errorf("Issue accepted path %q", path)
			}
		})
	}
}

func TestLoadOrCreateKeyGeneratesOne(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.key")
	key, err := LoadOrCreateKey(path)
	if err != nil {
		t.Fatalf("LoadOrCreateKey: %v", err)
	}
	if len(key) < 32 {
		t.Errorf("key is %d bytes, want at least 32", len(key))
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("the key was not written: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("key mode is %o, want 600", perm)
	}

	// A second call reads what the first wrote; regenerating would log
	// everybody out on every restart.
	again, err := LoadOrCreateKey(path)
	if err != nil {
		t.Fatalf("second LoadOrCreateKey: %v", err)
	}
	if string(again) != string(key) {
		t.Error("the key changed between calls")
	}
}

func TestLoadOrCreateKeyCreatesTheDirectory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "deeper", "session.key")
	if _, err := LoadOrCreateKey(path); err != nil {
		t.Fatalf("LoadOrCreateKey: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Errorf("the key was not written: %v", err)
	}
}

// A key other accounts can read is not a key. Refusing is the only way the
// mistake gets noticed.
func TestLoadOrCreateKeyRefusesALooseKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.key")
	if err := os.WriteFile(path, []byte("0123456789abcdef0123456789abcdef"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOrCreateKey(path); err == nil {
		t.Fatal("LoadOrCreateKey accepted a world-readable key")
	}
}

func TestLoadOrCreateKeyRefusesAShortKey(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.key")
	if err := os.WriteFile(path, []byte("short"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOrCreateKey(path); err == nil {
		t.Fatal("LoadOrCreateKey accepted a five-byte key")
	}
}

func flip(s string) string {
	if s == "" {
		return "x"
	}
	b := []byte(s)
	if b[0] == 'A' {
		b[0] = 'B'
	} else {
		b[0] = 'A'
	}
	return string(b)
}
