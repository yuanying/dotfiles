package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// testRouter wires a router whose backends are recorded rather than dialled.
func testRouter(t *testing.T, cfg *Config) (*Router, map[int]*backend) {
	t.Helper()
	backends := map[int]*backend{}
	rt := &Router{
		gate: &gate{
			signer:    testSigner(t, epoch),
			authHost:  cfg.AuthHost(),
			cookieTTL: time.Hour,
		},
		auth: &authHost{
			signer:   testSigner(t, epoch),
			github:   newTestGitHub(t, &fakeGitHub{code: "c", token: "t", login: "yuanying"}),
			newNonce: func() string { return "n" },
		},
		newBackend: func(port int) http.Handler {
			b := &backend{}
			backends[port] = b
			return b
		},
	}
	rt.Set(cfg)
	return rt, backends
}

func routerConfig(t *testing.T) *Config {
	t.Helper()
	c, err := Parse([]byte(authTestConfig))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func hostRequest(host, target string) *http.Request {
	r := httptest.NewRequest("GET", target, nil)
	r.Host = host
	return r
}

func TestRouterReachesTheRightBackend(t *testing.T) {
	cfg := routerConfig(t)
	rt, backends := testRouter(t, cfg)

	w := httptest.NewRecorder()
	rt.ServeHTTP(w, hostRequest("docs.poissonnerie.dev", "/readme"))

	if b := backends[8080]; b == nil || !b.hit {
		t.Fatalf("port 8080 was not reached; status %d", w.Code)
	}
	if b := backends[7860]; b != nil && b.hit {
		t.Error("the wrong backend was reached")
	}
}

func TestRouterSendsTheAuthHostToTheAuthHandler(t *testing.T) {
	cfg := routerConfig(t)
	rt, backends := testRouter(t, cfg)

	w := httptest.NewRecorder()
	rt.ServeHTTP(w, hostRequest("auth.poissonnerie.dev", "/"))

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want the auth host index", w.Code)
	}
	if !strings.Contains(w.Body.String(), "poissonnerie.dev") {
		t.Errorf("body = %q", w.Body)
	}
	for port, b := range backends {
		if b.hit {
			t.Errorf("port %d was reached for an auth-host request", port)
		}
	}
}

// The wildcard AAAA record means every label in the zone arrives here, and
// anything at all arrives at the IPv6 address.
func TestRouterRefusesUndeclaredHosts(t *testing.T) {
	cfg := routerConfig(t)
	rt, backends := testRouter(t, cfg)

	for _, host := range []string{
		"nope.poissonnerie.dev",
		"poissonnerie.dev",
		"sd-webui.oeilvert.dev",
		"[2405:6581:8580:302::151]",
		"",
	} {
		t.Run(host, func(t *testing.T) {
			w := httptest.NewRecorder()
			rt.ServeHTTP(w, hostRequest(host, "/"))
			if w.Code == http.StatusOK {
				t.Errorf("status = 200 for %q", host)
			}
			for port, b := range backends {
				if b.hit {
					t.Errorf("port %d was reached for %q", port, host)
				}
			}
		})
	}
}

func TestRouterAppliesAuthentication(t *testing.T) {
	cfg := routerConfig(t)
	rt, backends := testRouter(t, cfg)

	w := httptest.NewRecorder()
	rt.ServeHTTP(w, hostRequest("sd-webui.poissonnerie.dev", "/generate"))

	if w.Code != http.StatusFound {
		t.Fatalf("status = %d, want a redirect to the auth host", w.Code)
	}
	if b := backends[7860]; b != nil && b.hit {
		t.Error("an authenticated service was reached without a login")
	}
}

func TestSetReplacesTheRoutingTable(t *testing.T) {
	cfg := routerConfig(t)
	rt, _ := testRouter(t, cfg)

	grown, err := Parse([]byte(authTestConfig + "  - name: llama\n    port: 8081\n    auth: none\n"))
	if err != nil {
		t.Fatal(err)
	}
	rt.Set(grown)

	w := httptest.NewRecorder()
	rt.ServeHTTP(w, hostRequest("llama.poissonnerie.dev", "/"))
	if w.Code != http.StatusOK {
		t.Errorf("status = %d; the new service is not routed", w.Code)
	}

	// And one that went away stops being served.
	shrunk, err := Parse([]byte("zone: poissonnerie.dev\nservices: []\n"))
	if err != nil {
		t.Fatal(err)
	}
	rt.Set(shrunk)

	w = httptest.NewRecorder()
	rt.ServeHTTP(w, hostRequest("docs.poissonnerie.dev", "/"))
	if w.Code == http.StatusOK {
		t.Error("a withdrawn service is still being served")
	}
}

func TestConfigReturnsWhatIsInForce(t *testing.T) {
	cfg := routerConfig(t)
	rt, _ := testRouter(t, cfg)
	if got := rt.Config(); got.Zone != "poissonnerie.dev" {
		t.Errorf("Config().Zone = %q", got.Zone)
	}
}

// A backend is built once per Set, not once per request.
func TestBackendsAreNotRebuiltPerRequest(t *testing.T) {
	cfg := routerConfig(t)
	built := 0
	rt := &Router{
		gate: &gate{signer: testSigner(t, epoch), authHost: cfg.AuthHost(), cookieTTL: time.Hour},
		auth: &authHost{signer: testSigner(t, epoch), newNonce: func() string { return "n" }},
		newBackend: func(port int) http.Handler {
			built++
			return &backend{}
		},
	}
	rt.Set(cfg)
	after := built

	for i := 0; i < 5; i++ {
		rt.ServeHTTP(httptest.NewRecorder(), hostRequest("docs.poissonnerie.dev", "/"))
	}
	if built != after {
		t.Errorf("built %d backends serving requests, want none", built-after)
	}
}

// docs/adr/0008: reload swaps the table while requests are in flight.
func TestSetIsSafeWhileServing(t *testing.T) {
	cfg := routerConfig(t)
	rt, _ := testRouter(t, cfg)
	grown, err := Parse([]byte(authTestConfig + "  - name: llama\n    port: 8081\n    auth: none\n"))
	if err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	stop := make(chan struct{})

	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			if i%2 == 0 {
				rt.Set(grown)
			} else {
				rt.Set(cfg)
			}
		}
	}()

	for i := 0; i < 200; i++ {
		w := httptest.NewRecorder()
		rt.ServeHTTP(w, hostRequest("docs.poissonnerie.dev", fmt.Sprintf("/%d", i)))
		if w.Code != http.StatusOK {
			t.Fatalf("request %d got %d while the table was being replaced", i, w.Code)
		}
	}
	close(stop)
	wg.Wait()
}
