package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
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
		newBackend: func(s Service) http.Handler {
			b := &backend{}
			backends[s.Port] = b
			return b
		},
	}
	rt.SetAPISigner(testAPISigner(t, epoch))
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

// Each backend is built for where its service says it is, not for the loopback
// (docs/adr/0011).
func TestBackendsAreBuiltForTheDeclaredHost(t *testing.T) {
	cfg, err := Parse([]byte("zone: z.dev\nservices:\n  - name: webui\n    host: sd-webui\n    port: 7860\n    auth: none\n  - name: local\n    port: 8080\n    auth: none\n"))
	if err != nil {
		t.Fatal(err)
	}
	upstreams := map[string]string{}
	rt := &Router{
		gate: &gate{signer: testSigner(t, epoch), authHost: cfg.AuthHost(), cookieTTL: time.Hour},
		auth: &authHost{signer: testSigner(t, epoch), newNonce: func() string { return "n" }},
		newBackend: func(s Service) http.Handler {
			upstreams[s.Name] = s.Upstream()
			return &backend{}
		},
	}
	rt.Set(cfg)

	if got := upstreams["webui"]; got != "sd-webui:7860" {
		t.Errorf("webui built for %q, want sd-webui:7860", got)
	}
	if got := upstreams["local"]; got != "127.0.0.1:8080" {
		t.Errorf("local built for %q, want 127.0.0.1:8080", got)
	}
}

// roundTripper records where the proxy would have connected.
type roundTripper struct{ req *http.Request }

func (rt *roundTripper) RoundTrip(r *http.Request) (*http.Response, error) {
	rt.req = r
	return &http.Response{StatusCode: http.StatusOK, Body: http.NoBody, Header: http.Header{}, Request: r}, nil
}

// The connection goes to the declared host, and the backend still sees the
// name the visitor used.
func TestReverseProxyConnectsToTheUpstream(t *testing.T) {
	for _, upstream := range []string{"sd-webui:7860", "127.0.0.1:8080", "[fd00:5d::2]:80"} {
		t.Run(upstream, func(t *testing.T) {
			rp := reverseProxy(upstream).(*httputil.ReverseProxy)
			rec := &roundTripper{}
			rp.Transport = rec

			rp.ServeHTTP(httptest.NewRecorder(), hostRequest("sd-webui.poissonnerie.dev", "/sdapi/v1/txt2img?x=1"))

			if rec.req == nil {
				t.Fatal("nothing was sent")
			}
			if rec.req.URL.Host != upstream {
				t.Errorf("connected to %q, want %q", rec.req.URL.Host, upstream)
			}
			if rec.req.URL.Scheme != "http" {
				t.Errorf("scheme = %q, want http", rec.req.URL.Scheme)
			}
			if rec.req.URL.Path != "/sdapi/v1/txt2img" || rec.req.URL.RawQuery != "x=1" {
				t.Errorf("forwarded %s", rec.req.URL)
			}
			if rec.req.Host != "sd-webui.poissonnerie.dev" {
				t.Errorf("Host = %q; the backend should see the public name", rec.req.Host)
			}
		})
	}
}

// A backend is built once per Set, not once per request.
func TestBackendsAreNotRebuiltPerRequest(t *testing.T) {
	cfg := routerConfig(t)
	built := 0
	rt := &Router{
		gate: &gate{signer: testSigner(t, epoch), authHost: cfg.AuthHost(), cookieTTL: time.Hour},
		auth: &authHost{signer: testSigner(t, epoch), newNonce: func() string { return "n" }},
		newBackend: func(Service) http.Handler {
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

// The API signer has to be reachable from a request that went through the
// whole router, not only from a gate assembled by hand (docs/adr/0010).
func TestRouterAdmitsABearerToken(t *testing.T) {
	cfg := routerConfig(t)
	rt, backends := testRouter(t, cfg)

	raw, err := rt.gate.apiSigner().Issue(Token{
		Kind: KindAPI, Subject: "yuanying", Service: "sd-webui",
		Expires: epoch.Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}

	r := hostRequest("sd-webui.poissonnerie.dev", "/generate")
	r.Header.Set("Authorization", "Bearer "+raw)
	w := httptest.NewRecorder()
	rt.ServeHTTP(w, r)

	b := backends[7860]
	if b == nil || !b.hit {
		t.Fatalf("the guarded backend was not reached; status %d", w.Code)
	}
	if b.user != "yuanying" {
		t.Errorf("the backend saw user %q", b.user)
	}
}

// Rotation has to survive the trip through the router, because that is what
// reload actually calls (docs/adr/0010).
func TestRouterRotatesTheAPIKey(t *testing.T) {
	cfg := routerConfig(t)
	rt, backends := testRouter(t, cfg)

	old, _ := rt.gate.apiSigner().Issue(Token{
		Kind: KindAPI, Subject: "yuanying", Service: "sd-webui",
		Expires: epoch.Add(time.Hour),
	})

	fresh := NewSigner([]byte("ffffffffffffffffffffffffffffffff"))
	fresh.now = func() time.Time { return epoch }
	rt.SetAPISigner(fresh)

	r := hostRequest("sd-webui.poissonnerie.dev", "/generate")
	r.Header.Set("Authorization", "Bearer "+old)
	w := httptest.NewRecorder()
	rt.ServeHTTP(w, r)

	if b := backends[7860]; b != nil && b.hit {
		t.Fatal("a token signed with the retired key still reached the backend")
	}
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", w.Code)
	}
}
