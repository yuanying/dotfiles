package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const goodConfig = `
zone: poissonnerie.dev
defaults:
  auth: required
services:
  - name: sd-viewer
    port: 8189
    auth: required
    viewers:
      logins:
        - yuanying
  - name: docs
    port: 8080
    auth: none
`

func TestParseReadsServices(t *testing.T) {
	c, err := Parse([]byte(goodConfig))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if c.Zone != "poissonnerie.dev" {
		t.Errorf("Zone = %q, want poissonnerie.dev", c.Zone)
	}
	if len(c.Services) != 2 {
		t.Fatalf("got %d services, want 2", len(c.Services))
	}
	sd := c.Services[0]
	if sd.Name != "sd-viewer" || sd.Port != 8189 || sd.Auth != AuthRequired {
		t.Errorf("first service = %+v", sd)
	}
	if len(sd.Viewers.Logins) != 1 || sd.Viewers.Logins[0] != "yuanying" {
		t.Errorf("logins = %v, want [yuanying]", sd.Viewers.Logins)
	}
	if c.Services[1].Auth != AuthNone {
		t.Errorf("docs auth = %q, want none", c.Services[1].Auth)
	}
}

// An omitted `auth` takes the value from `defaults`, and `defaults` itself is
// optional -- a service that says nothing anywhere is authenticated, because
// the safe direction is the one that asks for a login.
func TestAuthDefaults(t *testing.T) {
	for _, tc := range []struct {
		name string
		yaml string
		want AuthMode
	}{
		{
			name: "inherits defaults",
			yaml: "zone: z.dev\ndefaults:\n  auth: none\nservices:\n  - name: a\n    port: 1\n",
			want: AuthNone,
		},
		{
			name: "required when nothing says otherwise",
			yaml: "zone: z.dev\nservices:\n  - name: a\n    port: 1\n    viewers:\n      logins: [someone]\n",
			want: AuthRequired,
		},
		{
			name: "service overrides defaults",
			yaml: "zone: z.dev\ndefaults:\n  auth: none\nservices:\n  - name: a\n    port: 1\n    auth: required\n    viewers:\n      logins: [someone]\n",
			want: AuthRequired,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, err := Parse([]byte(tc.yaml))
			if err != nil {
				t.Fatalf("Parse: %v", err)
			}
			if got := c.Services[0].Auth; got != tc.want {
				t.Errorf("auth = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestParseRejects(t *testing.T) {
	for _, tc := range []struct {
		name string
		yaml string
		want string // substring the error has to carry
	}{
		{
			name: "no zone",
			yaml: "services: []\n",
			want: "zone",
		},
		{
			name: "a name with a dot",
			yaml: "zone: z.dev\nservices:\n  - name: llama.gpu\n    port: 1\n    auth: none\n",
			want: "one label",
		},
		{
			name: "the reserved auth name",
			yaml: "zone: z.dev\nservices:\n  - name: auth\n    port: 1\n    auth: none\n",
			want: "reserved",
		},
		{
			name: "an uppercase name",
			yaml: "zone: z.dev\nservices:\n  - name: Llama\n    port: 1\n    auth: none\n",
			want: "Llama",
		},
		{
			name: "a name starting with a hyphen",
			yaml: "zone: z.dev\nservices:\n  - name: -llama\n    port: 1\n    auth: none\n",
			want: "-llama",
		},
		{
			name: "a duplicate name",
			yaml: "zone: z.dev\nservices:\n  - name: a\n    port: 1\n    auth: none\n  - name: a\n    port: 2\n    auth: none\n",
			want: "twice",
		},
		{
			name: "a duplicate port",
			yaml: "zone: z.dev\nservices:\n  - name: a\n    port: 1\n    auth: none\n  - name: b\n    port: 1\n    auth: none\n",
			want: "port 1",
		},
		{
			name: "a port out of range",
			yaml: "zone: z.dev\nservices:\n  - name: a\n    port: 70000\n    auth: none\n",
			want: "70000",
		},
		{
			name: "a missing port",
			yaml: "zone: z.dev\nservices:\n  - name: a\n    auth: none\n",
			want: "port",
		},
		{
			name: "an unknown auth mode",
			yaml: "zone: z.dev\nservices:\n  - name: a\n    port: 1\n    auth: maybe\n",
			want: "maybe",
		},
		{
			name: "authenticated with nobody allowed",
			yaml: "zone: z.dev\nservices:\n  - name: a\n    port: 1\n    auth: required\n",
			want: "viewer",
		},
		{
			name: "an unknown key",
			yaml: "zone: z.dev\nservices:\n  - name: a\n    port: 1\n    auth: none\n    prot: 2\n",
			want: "prot",
		},
		{
			name: "not yaml at all",
			yaml: "\tthis is not: [yaml\n",
			want: "",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Parse([]byte(tc.yaml))
			if err == nil {
				t.Fatalf("Parse accepted it; want an error")
			}
			if tc.want != "" && !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error %q does not mention %q", err, tc.want)
			}
		})
	}
}

// The keys 0005 removed. Someone updating an old declaration file should be
// told what to do, not just that the key is unknown.
func TestParseExplainsRemovedKeys(t *testing.T) {
	for _, tc := range []struct{ name, yaml, want string }{
		{
			name: "team_domain",
			yaml: "zone: z.dev\nteam_domain: x.cloudflareaccess.com\nservices: []\n",
			want: "team_domain",
		},
		{
			name: "origin",
			yaml: "zone: z.dev\norigin: 2405:6581::1\nservices: []\n",
			want: "origin",
		},
		{
			name: "aud",
			yaml: "zone: z.dev\nservices:\n  - name: a\n    port: 1\n    auth: none\n    aud: deadbeef\n",
			want: "aud",
		},
		{
			name: "viewers.emails",
			yaml: "zone: z.dev\nservices:\n  - name: a\n    port: 1\n    auth: required\n    viewers:\n      emails: [me@example.com]\n",
			want: "logins",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Parse([]byte(tc.yaml))
			if err == nil {
				t.Fatalf("Parse accepted it; want an error")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error %q does not mention %q", err, tc.want)
			}
			if !strings.Contains(err.Error(), "0005") && !strings.Contains(err.Error(), "0007") {
				t.Errorf("error %q does not point at the record that removed it", err)
			}
		})
	}
}

// Reporting one problem per run means fixing a file by repeated attempts.
func TestParseReportsEveryProblem(t *testing.T) {
	_, err := Parse([]byte("zone: z.dev\nservices:\n  - name: a.b\n    port: 0\n    auth: none\n"))
	if err == nil {
		t.Fatal("Parse accepted it; want an error")
	}
	if !strings.Contains(err.Error(), "one label") || !strings.Contains(err.Error(), "0") {
		t.Errorf("error %q does not carry both problems", err)
	}
}

func TestNoServicesIsValid(t *testing.T) {
	c, err := Parse([]byte("zone: z.dev\nservices: []\n"))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(c.Services) != 0 {
		t.Errorf("got %d services, want none", len(c.Services))
	}
	// The auth host still needs a certificate even with nothing published.
	if got := c.Hostnames(); len(got) != 1 || got[0] != "auth.z.dev" {
		t.Errorf("Hostnames() = %v, want [auth.z.dev]", got)
	}
}

func TestHostnames(t *testing.T) {
	c, err := Parse([]byte(goodConfig))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	want := []string{"auth.poissonnerie.dev", "docs.poissonnerie.dev", "sd-viewer.poissonnerie.dev"}
	got := c.Hostnames()
	if len(got) != len(want) {
		t.Fatalf("Hostnames() = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("Hostnames()[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestAuthHost(t *testing.T) {
	c, _ := Parse([]byte(goodConfig))
	if got := c.AuthHost(); got != "auth.poissonnerie.dev" {
		t.Errorf("AuthHost() = %q", got)
	}
}

func TestLookup(t *testing.T) {
	c, _ := Parse([]byte(goodConfig))
	for _, tc := range []struct {
		host string
		want string // service name, or "" for no match
	}{
		{"sd-viewer.poissonnerie.dev", "sd-viewer"},
		{"docs.poissonnerie.dev", "docs"},
		{"SD-VIEWER.poissonnerie.dev", "sd-viewer"}, // hostnames are case-insensitive
		{"sd-viewer.poissonnerie.dev:443", "sd-viewer"},
		{"auth.poissonnerie.dev", ""},
		{"nope.poissonnerie.dev", ""},
		{"sd-viewer.oeilvert.dev", ""}, // right label, another zone
		{"", ""},
	} {
		t.Run(tc.host, func(t *testing.T) {
			s, ok := c.Lookup(tc.host)
			if tc.want == "" {
				if ok {
					t.Errorf("Lookup(%q) matched %q, want no match", tc.host, s.Name)
				}
				return
			}
			if !ok {
				t.Fatalf("Lookup(%q) found nothing, want %q", tc.host, tc.want)
			}
			if s.Name != tc.want {
				t.Errorf("Lookup(%q) = %q, want %q", tc.host, s.Name, tc.want)
			}
		})
	}
}

// certmagic asks this before talking to Let's Encrypt. A wildcard AAAA record
// means any label arrives here, so anything not declared has to be refused.
func TestAllows(t *testing.T) {
	c, _ := Parse([]byte(goodConfig))
	for host, want := range map[string]bool{
		"sd-viewer.poissonnerie.dev": true,
		"docs.poissonnerie.dev":      true,
		"auth.poissonnerie.dev":      true,
		"nope.poissonnerie.dev":      false,
		"poissonnerie.dev":           false,
		"sd-viewer.oeilvert.dev":     false,
		"":                           false,
	} {
		if got := c.Allows(host); got != want {
			t.Errorf("Allows(%q) = %v, want %v", host, got, want)
		}
	}
}

func TestLoadReadsAFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "services.test.yaml")
	if err := os.WriteFile(path, []byte(goodConfig), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.Zone != "poissonnerie.dev" {
		t.Errorf("Zone = %q", c.Zone)
	}
}

func TestLoadMissingFile(t *testing.T) {
	if _, err := Load(filepath.Join(t.TempDir(), "absent.yaml")); err == nil {
		t.Fatal("Load accepted a missing file")
	}
}

// The files this repository actually ships have to parse.
func TestShippedDeclarationsParse(t *testing.T) {
	paths, err := filepath.Glob("../services.*.yaml")
	if err != nil || len(paths) == 0 {
		t.Skipf("no declaration files alongside: %v", err)
	}
	for _, p := range paths {
		t.Run(filepath.Base(p), func(t *testing.T) {
			if _, err := Load(p); err != nil {
				t.Errorf("Load(%s): %v", p, err)
			}
		})
	}
}
