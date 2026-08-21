package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const overlayConfig = `
zone: poissonnerie.dev
services:
  - name: sd-webui
    port: 7860
    auth: required
    viewers:
      logins:
        - yuanying
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

func overlaid(t *testing.T, declaration, overlay string) *Config {
	t.Helper()
	c, err := Parse([]byte(declaration))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	o, err := ParseOverlay([]byte(overlay))
	if err != nil {
		t.Fatalf("ParseOverlay: %v", err)
	}
	if err := c.Apply(o); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	return c
}

func TestOverlayAddsViewers(t *testing.T) {
	c := overlaid(t, overlayConfig, "services:\n  - name: sd-webui\n    viewers:\n      logins: [iwaco]\n")

	svc, _ := c.Lookup("sd-webui.poissonnerie.dev")
	if got := strings.Join(svc.Viewers.Logins, ","); got != "yuanying,iwaco" {
		t.Errorf("logins = %q, want the declared one plus the overlay", got)
	}
	if svc.Port != 7860 {
		t.Errorf("port = %d; the overlay said nothing about it", svc.Port)
	}

	other, _ := c.Lookup("sd-viewer.poissonnerie.dev")
	if got := strings.Join(other.Viewers.Logins, ","); got != "yuanying" {
		t.Errorf("sd-viewer logins = %q; it was not mentioned", got)
	}
}

func TestOverlayDoesNotDuplicate(t *testing.T) {
	c := overlaid(t, overlayConfig, "services:\n  - name: sd-webui\n    viewers:\n      logins: [yuanying, YUANYING, iwaco]\n")
	svc, _ := c.Lookup("sd-webui.poissonnerie.dev")
	if got := strings.Join(svc.Viewers.Logins, ","); got != "yuanying,iwaco" {
		t.Errorf("logins = %q; GitHub names are case-insensitive", got)
	}
}

// A port that moved, or a service turned off behind a login for an afternoon,
// without touching a public repository.
func TestOverlayOverridesPortAndAuth(t *testing.T) {
	c := overlaid(t, overlayConfig, "services:\n  - name: sd-webui\n    port: 7861\n  - name: docs\n    auth: required\n    viewers:\n      logins: [yuanying]\n")

	webui, _ := c.Lookup("sd-webui.poissonnerie.dev")
	if webui.Port != 7861 {
		t.Errorf("port = %d, want the overlay's 7861", webui.Port)
	}
	if webui.Auth != AuthRequired {
		t.Errorf("auth = %q; the overlay said nothing, so the declaration stands", webui.Auth)
	}

	docs, _ := c.Lookup("docs.poissonnerie.dev")
	if docs.Auth != AuthRequired {
		t.Errorf("docs auth = %q, want the overlay's required", docs.Auth)
	}
	if docs.Port != 8080 {
		t.Errorf("docs port = %d, want the declared 8080", docs.Port)
	}
}

// The reason this exists: a service the repository never hears about.
func TestOverlayDefinesANewService(t *testing.T) {
	c := overlaid(t, overlayConfig, "services:\n  - name: private\n    port: 9000\n    auth: required\n    viewers:\n      logins: [yuanying]\n")

	svc, ok := c.Lookup("private.poissonnerie.dev")
	if !ok {
		t.Fatal("the overlay's service is not published")
	}
	if svc.Port != 9000 || svc.Auth != AuthRequired {
		t.Errorf("got %+v", svc)
	}
	// And it gets a certificate like any other.
	if !c.Allows("private.poissonnerie.dev") {
		t.Error("the overlay's service is not in the certificate allow-list")
	}
}

// docs/adr/0004's defaults still apply to something the overlay introduces.
func TestANewServiceInheritsDefaults(t *testing.T) {
	c := overlaid(t,
		"zone: z.dev\ndefaults:\n  auth: none\nservices: []\n",
		"services:\n  - name: thing\n    port: 9000\n")

	svc, ok := c.Lookup("thing.z.dev")
	if !ok {
		t.Fatal("not published")
	}
	if svc.Auth != AuthNone {
		t.Errorf("auth = %q, want the declaration's default", svc.Auth)
	}
}

func TestOverlayIsValidatedAfterMerging(t *testing.T) {
	for _, tc := range []struct{ name, overlay, want string }{
		{
			name:    "a new service with no port",
			overlay: "services:\n  - name: private\n    auth: none\n",
			want:    "port",
		},
		{
			name:    "a new service whose name is not a label",
			overlay: "services:\n  - name: not.a.label\n    port: 9000\n    auth: none\n",
			want:    "one label",
		},
		{
			name:    "a new service called auth",
			overlay: "services:\n  - name: auth\n    port: 9000\n    auth: none\n",
			want:    "reserved",
		},
		{
			name:    "a port that collides with a declared one",
			overlay: "services:\n  - name: private\n    port: 7860\n    auth: none\n",
			want:    "port 7860",
		},
		{
			name:    "a port moved onto another service's port",
			overlay: "services:\n  - name: sd-webui\n    port: 8189\n",
			want:    "port 8189",
		},
		{
			name:    "viewers on something the overlay leaves public",
			overlay: "services:\n  - name: docs\n    viewers:\n      logins: [someone]\n",
			want:    "ignored",
		},
		{
			name:    "an entry with no name",
			overlay: "services:\n  - port: 9000\n",
			want:    "name",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, err := Parse([]byte(overlayConfig))
			if err != nil {
				t.Fatal(err)
			}
			o, err := ParseOverlay([]byte(tc.overlay))
			if err != nil {
				if !strings.Contains(err.Error(), tc.want) {
					t.Errorf("ParseOverlay error %q does not mention %q", err, tc.want)
				}
				return
			}
			err = c.Apply(o)
			if err == nil {
				t.Fatalf("Apply accepted it")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error %q does not mention %q", err, tc.want)
			}
		})
	}
}

// The zone is the declaration's to name: an overlay that could change it would
// move every hostname and every certificate at once.
func TestOverlayCannotSetTheZone(t *testing.T) {
	if _, err := ParseOverlay([]byte("zone: elsewhere.dev\nservices: []\n")); err == nil {
		t.Error("an overlay was allowed to name a zone")
	}
}

func TestOverlayRejectsUnknownKeys(t *testing.T) {
	if _, err := ParseOverlay([]byte("service:\n  - name: a\n")); err == nil {
		t.Error("a misspelled top-level key was accepted")
	}
	if _, err := ParseOverlay([]byte("services:\n  - name: a\n    viewers:\n      emails: [x@example.com]\n")); err == nil {
		t.Error("viewers.emails was accepted")
	}
}

func TestNilOverlayChangesNothing(t *testing.T) {
	c, _ := Parse([]byte(overlayConfig))
	if err := c.Apply(nil); err != nil {
		t.Fatalf("Apply(nil): %v", err)
	}
	if len(c.Services) != 3 {
		t.Errorf("got %d services", len(c.Services))
	}
}

func TestLoadOverlay(t *testing.T) {
	path := filepath.Join(t.TempDir(), "services.local.yaml")
	if err := os.WriteFile(path, []byte("services:\n  - name: sd-webui\n    viewers:\n      logins: [iwaco]\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	o, err := LoadOverlay(path)
	if err != nil {
		t.Fatalf("LoadOverlay: %v", err)
	}
	if o == nil || len(o.Services) != 1 {
		t.Errorf("got %+v", o)
	}
}

// Not having one is the ordinary case.
func TestLoadOverlayWhenThereIsNone(t *testing.T) {
	o, err := LoadOverlay(filepath.Join(t.TempDir(), "absent.yaml"))
	if err != nil {
		t.Errorf("LoadOverlay on a missing file: %v", err)
	}
	if o != nil {
		t.Errorf("got %+v, want nil", o)
	}
}

func TestLoadOverlayReportsBadYAML(t *testing.T) {
	path := filepath.Join(t.TempDir(), "services.local.yaml")
	os.WriteFile(path, []byte("services: not-a-list\n"), 0o600)
	if _, err := LoadOverlay(path); err == nil {
		t.Error("a malformed overlay was accepted")
	}
}

func TestUnreachableServices(t *testing.T) {
	c, _ := Parse([]byte("zone: z.dev\nservices:\n  - name: a\n    port: 1\n    auth: required\n  - name: b\n    port: 2\n    auth: required\n    viewers:\n      logins: [someone]\n  - name: c\n    port: 3\n    auth: none\n"))

	got := c.Unreachable()
	if len(got) != 1 || got[0] != "a" {
		t.Errorf("Unreachable() = %v, want [a]", got)
	}
}
