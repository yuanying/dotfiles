package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func testGate(t *testing.T, now time.Time) *gate {
	t.Helper()
	g := &gate{
		signer:    testSigner(t, now),
		authHost:  "auth.poissonnerie.dev",
		cookieTTL: 7 * 24 * time.Hour,
		apiTTL:    90 * 24 * time.Hour,
	}
	g.setAPISigner(testAPISigner(t, now))
	return g
}

// The API signer holds a different key from the session signer, which is the
// whole point of docs/adr/0010: rotating one does not disturb the other.
func testAPISigner(t *testing.T, now time.Time) *Signer {
	t.Helper()
	s := NewSigner([]byte("89abcdef0123456789abcdef01234567"))
	s.now = func() time.Time { return now }
	return s
}

// backend records what actually reached it.
type backend struct {
	hit   bool
	user  string
	path  string
	authz string
}

func (b *backend) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	b.hit = true
	b.user = r.Header.Get(userHeader)
	b.path = r.URL.Path
	b.authz = r.Header.Get("Authorization")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("backend"))
}

var webui = Service{Name: "sd-webui", Port: 7860, Auth: AuthRequired, Viewers: Viewers{Logins: []string{"yuanying"}}}
var docs = Service{Name: "docs", Port: 8080, Auth: AuthNone}

func request(method, target string) *http.Request {
	r := httptest.NewRequest(method, target, nil)
	r.Host = "sd-webui.poissonnerie.dev"
	return r
}

func TestPublicServiceNeedsNoLogin(t *testing.T) {
	g := testGate(t, epoch)
	b := &backend{}
	w := httptest.NewRecorder()
	g.serve(w, request("GET", "http://docs.poissonnerie.dev/readme"), docs, b)

	if !b.hit {
		t.Fatalf("the backend was not reached; got %d", w.Code)
	}
	if b.user != "" {
		t.Errorf("an anonymous request carried a user of %q", b.user)
	}
}

func TestUnauthenticatedRequestGoesToTheAuthHost(t *testing.T) {
	g := testGate(t, epoch)
	b := &backend{}
	w := httptest.NewRecorder()
	g.serve(w, request("GET", "http://sd-webui.poissonnerie.dev/generate?seed=1"), webui, b)

	if b.hit {
		t.Fatal("the backend was reached without a login")
	}
	if w.Code != http.StatusFound {
		t.Fatalf("status = %d, want 302", w.Code)
	}
	loc, err := url.Parse(w.Header().Get("Location"))
	if err != nil {
		t.Fatalf("Location: %v", err)
	}
	if loc.Host != "auth.poissonnerie.dev" || loc.Path != "/login" {
		t.Errorf("redirected to %s", loc)
	}
	rd := loc.Query().Get("rd")
	if rd != "https://sd-webui.poissonnerie.dev/generate?seed=1" {
		t.Errorf("rd = %q, does not carry where they were going", rd)
	}
}

func TestAValidCookieReachesTheBackend(t *testing.T) {
	g := testGate(t, epoch)
	raw, err := g.signer.Issue(Token{
		Kind: KindCookie, Subject: "yuanying", Service: "sd-webui",
		Expires: epoch.Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}

	b := &backend{}
	r := request("GET", "http://sd-webui.poissonnerie.dev/generate")
	r.AddCookie(&http.Cookie{Name: cookieName, Value: raw})
	w := httptest.NewRecorder()
	g.serve(w, r, webui, b)

	if !b.hit {
		t.Fatalf("a logged-in request did not reach the backend; got %d", w.Code)
	}
	if b.user != "yuanying" {
		t.Errorf("the backend saw user %q, want yuanying", b.user)
	}
}

// A cookie that does not verify is not an error to show the visitor; it is a
// visitor who needs to log in again.
func TestABadCookieSendsThemToLogIn(t *testing.T) {
	g := testGate(t, epoch)
	other := NewSigner([]byte("fedcba9876543210fedcba9876543210"))
	other.now = func() time.Time { return epoch }

	elsewhere, _ := g.signer.Issue(Token{Kind: KindCookie, Subject: "yuanying", Service: "docs", Expires: epoch.Add(time.Hour)})
	foreign, _ := other.Issue(Token{Kind: KindCookie, Subject: "yuanying", Service: "sd-webui", Expires: epoch.Add(time.Hour)})
	expired, _ := g.signer.Issue(Token{Kind: KindCookie, Subject: "yuanying", Service: "sd-webui", Expires: epoch.Add(-time.Second)})
	handover, _ := g.signer.Issue(Token{Kind: KindHandover, Subject: "yuanying", Service: "sd-webui", Path: "/", Expires: epoch.Add(time.Minute)})

	for name, value := range map[string]string{
		"nonsense":            "not-a-token",
		"empty":               "",
		"for another service": elsewhere,
		"signed elsewhere":    foreign,
		"expired":             expired,
		"a handover token":    handover,
	} {
		t.Run(name, func(t *testing.T) {
			b := &backend{}
			r := request("GET", "http://sd-webui.poissonnerie.dev/")
			r.AddCookie(&http.Cookie{Name: cookieName, Value: value})
			w := httptest.NewRecorder()
			g.serve(w, r, webui, b)

			if b.hit {
				t.Fatal("the backend was reached")
			}
			if w.Code != http.StatusFound {
				t.Errorf("status = %d, want 302 to the auth host", w.Code)
			}
		})
	}
}

func TestHandoverSetsTheCookie(t *testing.T) {
	g := testGate(t, epoch)
	handover, err := g.signer.Issue(Token{
		Kind: KindHandover, Subject: "yuanying", Service: "sd-webui",
		Path: "/generate?seed=1", Expires: epoch.Add(30 * time.Second),
	})
	if err != nil {
		t.Fatal(err)
	}

	b := &backend{}
	w := httptest.NewRecorder()
	g.serve(w, request("GET", setPath+"?t="+url.QueryEscape(handover)), webui, b)

	if b.hit {
		t.Fatal("the handover was forwarded to the backend")
	}
	if w.Code != http.StatusFound {
		t.Fatalf("status = %d, want 302", w.Code)
	}
	if got := w.Header().Get("Location"); got != "/generate?seed=1" {
		t.Errorf("Location = %q, want the path they were going to", got)
	}

	cookies := w.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("got %d cookies, want 1", len(cookies))
	}
	c := cookies[0]
	if c.Name != cookieName {
		t.Errorf("cookie name = %q", c.Name)
	}
	if !c.Secure {
		t.Error("the session cookie is not Secure")
	}
	if !c.HttpOnly {
		t.Error("the session cookie is not HttpOnly")
	}
	if c.SameSite != http.SameSiteLaxMode {
		t.Errorf("SameSite = %v, want Lax", c.SameSite)
	}
	// 0007: host-only. A Domain attribute would offer this cookie to every
	// other name in the zone, including a service published with auth: none.
	if c.Domain != "" {
		t.Errorf("the session cookie has Domain=%q; it must be host-only", c.Domain)
	}
	if c.Path != "/" {
		t.Errorf("cookie path = %q, want /", c.Path)
	}

	// And the cookie it set actually works.
	if _, err := g.signer.Verify(c.Value, KindCookie, "sd-webui"); err != nil {
		t.Errorf("the cookie it set does not verify: %v", err)
	}
}

func TestHandoverRefusesWhatItCannotVerify(t *testing.T) {
	g := testGate(t, epoch)
	elsewhere, _ := g.signer.Issue(Token{Kind: KindHandover, Subject: "yuanying", Service: "docs", Path: "/", Expires: epoch.Add(time.Minute)})
	cookie, _ := g.signer.Issue(Token{Kind: KindCookie, Subject: "yuanying", Service: "sd-webui", Expires: epoch.Add(time.Hour)})

	for name, value := range map[string]string{
		"nothing":             "",
		"nonsense":            "garbage",
		"for another service": elsewhere,
		"a session cookie":    cookie,
	} {
		t.Run(name, func(t *testing.T) {
			b := &backend{}
			w := httptest.NewRecorder()
			g.serve(w, request("GET", setPath+"?t="+url.QueryEscape(value)), webui, b)

			if b.hit {
				t.Fatal("the backend was reached")
			}
			if w.Code != http.StatusForbidden {
				t.Errorf("status = %d, want 403", w.Code)
			}
			if len(w.Result().Cookies()) != 0 {
				t.Error("a cookie was set anyway")
			}
		})
	}
}

func TestLogoutClearsTheCookie(t *testing.T) {
	g := testGate(t, epoch)
	b := &backend{}
	w := httptest.NewRecorder()
	g.serve(w, request("GET", logoutPath), webui, b)

	if b.hit {
		t.Fatal("logout was forwarded to the backend")
	}
	cookies := w.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatalf("got %d cookies, want 1", len(cookies))
	}
	if cookies[0].MaxAge >= 0 {
		t.Errorf("MaxAge = %d, want a negative value to clear it", cookies[0].MaxAge)
	}
}

// The reserved prefix never reaches a backend, whatever it is used for and
// whether or not the service asks for a login.
func TestReservedPrefixIsNeverForwarded(t *testing.T) {
	for _, svc := range []Service{webui, docs} {
		t.Run(string(svc.Name), func(t *testing.T) {
			g := testGate(t, epoch)
			b := &backend{}
			w := httptest.NewRecorder()
			g.serve(w, request("GET", authPrefix+"anything"), svc, b)
			if b.hit {
				t.Errorf("%s reached the backend", authPrefix+"anything")
			}
			if w.Code == http.StatusOK {
				t.Errorf("status = 200 for an unknown reserved path")
			}
		})
	}
}

// A backend that trusts the identity header must not be reachable by anyone
// who simply sets it.
func TestTheIdentityHeaderCannotBeForged(t *testing.T) {
	g := testGate(t, epoch)

	t.Run("on a public service", func(t *testing.T) {
		b := &backend{}
		r := request("GET", "http://docs.poissonnerie.dev/")
		r.Header.Set(userHeader, "root")
		w := httptest.NewRecorder()
		g.serve(w, r, docs, b)
		if !b.hit {
			t.Fatal("the backend was not reached")
		}
		if b.user != "" {
			t.Errorf("the backend saw a forged user %q", b.user)
		}
	})

	t.Run("with a valid session", func(t *testing.T) {
		raw, _ := g.signer.Issue(Token{Kind: KindCookie, Subject: "yuanying", Service: "sd-webui", Expires: epoch.Add(time.Hour)})
		b := &backend{}
		r := request("GET", "http://sd-webui.poissonnerie.dev/")
		r.Header.Set(userHeader, "root")
		r.AddCookie(&http.Cookie{Name: cookieName, Value: raw})
		w := httptest.NewRecorder()
		g.serve(w, r, webui, b)
		if !b.hit {
			t.Fatal("the backend was not reached")
		}
		if b.user != "yuanying" {
			t.Errorf("the backend saw %q, want the signed identity yuanying", b.user)
		}
	})
}

func TestRedirectPreservesTheQuery(t *testing.T) {
	g := testGate(t, epoch)
	w := httptest.NewRecorder()
	g.serve(w, request("GET", "http://sd-webui.poissonnerie.dev/a/b?x=1&y=2#frag"), webui, &backend{})

	loc, _ := url.Parse(w.Header().Get("Location"))
	rd := loc.Query().Get("rd")
	if !strings.Contains(rd, "x=1") || !strings.Contains(rd, "y=2") {
		t.Errorf("rd = %q, lost the query", rd)
	}
}

// docs/adr/0010: a client that presents a valid bearer token gets in, and the
// backend sees the same identity header a browser session produces.
func TestABearerTokenReachesTheBackend(t *testing.T) {
	g := testGate(t, epoch)
	raw, err := g.apiSigner().Issue(Token{
		Kind: KindAPI, Subject: "yuanying", Service: "sd-webui",
		Expires: epoch.Add(90 * 24 * time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}

	b := &backend{}
	r := request("GET", "http://sd-webui.poissonnerie.dev/generate")
	r.Header.Set("Authorization", "Bearer "+raw)
	w := httptest.NewRecorder()
	g.serve(w, r, webui, b)

	if !b.hit {
		t.Fatalf("a bearer token did not reach the backend; got %d", w.Code)
	}
	if b.user != "yuanying" {
		t.Errorf("the backend saw user %q, want yuanying", b.user)
	}
	// The proxy consumed it, so it does not go on to the backend, which may
	// well want the header for its own API key.
	if b.authz != "" {
		t.Errorf("the backend saw Authorization = %q; it should have been consumed", b.authz)
	}
}

// The scheme is matched case-insensitively, as RFC 7235 requires.
func TestBearerSchemeIsCaseInsensitive(t *testing.T) {
	g := testGate(t, epoch)
	raw, _ := g.apiSigner().Issue(Token{Kind: KindAPI, Subject: "yuanying", Service: "sd-webui", Expires: epoch.Add(time.Hour)})

	b := &backend{}
	r := request("GET", "http://sd-webui.poissonnerie.dev/")
	r.Header.Set("Authorization", "bearer "+raw)
	w := httptest.NewRecorder()
	g.serve(w, r, webui, b)

	if !b.hit {
		t.Fatalf("a lowercase scheme was refused; got %d", w.Code)
	}
}

// docs/adr/0010: a request that asked to be authenticated is told it failed,
// rather than being redirected to a login page it cannot use.
func TestABadBearerTokenIsRefusedNotRedirected(t *testing.T) {
	g := testGate(t, epoch)
	elsewhere, _ := g.apiSigner().Issue(Token{Kind: KindAPI, Subject: "yuanying", Service: "docs", Expires: epoch.Add(time.Hour)})
	expired, _ := g.apiSigner().Issue(Token{Kind: KindAPI, Subject: "yuanying", Service: "sd-webui", Expires: epoch.Add(-time.Second)})
	// Signed with the session key rather than the API key: this is the pair
	// the second key exists to keep apart.
	sessionKeyed, _ := g.signer.Issue(Token{Kind: KindAPI, Subject: "yuanying", Service: "sd-webui", Expires: epoch.Add(time.Hour)})
	cookie, _ := g.signer.Issue(Token{Kind: KindCookie, Subject: "yuanying", Service: "sd-webui", Expires: epoch.Add(time.Hour)})

	for name, header := range map[string]string{
		"nonsense":                   "Bearer not-a-token",
		"empty":                      "Bearer ",
		"no scheme":                  "just-a-token",
		"another scheme":             "Basic eXVhbnlpbmc6aHVudGVyMg==",
		"for another service":        "Bearer " + elsewhere,
		"expired":                    "Bearer " + expired,
		"signed with the cookie key": "Bearer " + sessionKeyed,
		"a session cookie":           "Bearer " + cookie,
	} {
		t.Run(name, func(t *testing.T) {
			b := &backend{}
			r := request("GET", "http://sd-webui.poissonnerie.dev/")
			r.Header.Set("Authorization", header)
			w := httptest.NewRecorder()
			g.serve(w, r, webui, b)

			if b.hit {
				t.Fatal("the backend was reached")
			}
			if w.Code != http.StatusUnauthorized {
				t.Errorf("status = %d, want 401", w.Code)
			}
			if !strings.HasPrefix(w.Header().Get("WWW-Authenticate"), "Bearer") {
				t.Errorf("WWW-Authenticate = %q", w.Header().Get("WWW-Authenticate"))
			}
		})
	}
}

// The browser is untouched by any of this: no Authorization header still means
// a redirect to the auth host (0007).
func TestNoAuthorizationHeaderStillRedirects(t *testing.T) {
	g := testGate(t, epoch)
	w := httptest.NewRecorder()
	g.serve(w, request("GET", "http://sd-webui.poissonnerie.dev/"), webui, &backend{})
	if w.Code != http.StatusFound {
		t.Errorf("status = %d, want 302", w.Code)
	}
}

// A service the proxy does not authenticate does not have its Authorization
// header eaten: the backend may be using it for an API key of its own.
func TestAPublicServiceKeepsItsAuthorizationHeader(t *testing.T) {
	g := testGate(t, epoch)
	b := &backend{}
	r := request("GET", "http://docs.poissonnerie.dev/")
	r.Header.Set("Authorization", "Bearer the-backends-own-key")
	w := httptest.NewRecorder()
	g.serve(w, r, docs, b)

	if !b.hit {
		t.Fatalf("the backend was not reached; got %d", w.Code)
	}
	if b.authz != "Bearer the-backends-own-key" {
		t.Errorf("the backend saw Authorization = %q, want it passed through", b.authz)
	}
}

func TestTokenEndpointMintsForALoggedInVisitor(t *testing.T) {
	g := testGate(t, epoch)
	session, _ := g.signer.Issue(Token{Kind: KindCookie, Subject: "yuanying", Service: "sd-webui", Expires: epoch.Add(time.Hour)})

	b := &backend{}
	r := request("GET", tokenPath)
	r.AddCookie(&http.Cookie{Name: cookieName, Value: session})
	w := httptest.NewRecorder()
	g.serve(w, r, webui, b)

	if b.hit {
		t.Fatal("the token endpoint was forwarded to the backend")
	}
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	if ct := w.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/plain") {
		t.Errorf("Content-Type = %q, want text/plain", ct)
	}

	raw := strings.TrimSpace(w.Body.String())
	tok, err := g.apiSigner().Verify(raw, KindAPI, "sd-webui")
	if err != nil {
		t.Fatalf("what it handed out does not verify: %v", err)
	}
	if tok.Subject != "yuanying" {
		t.Errorf("Subject = %q, want the logged-in visitor", tok.Subject)
	}
	if want := epoch.Add(90 * 24 * time.Hour); !tok.Expires.Equal(want) {
		t.Errorf("Expires = %v, want %v", tok.Expires, want)
	}
}

func TestTokenEndpointNeedsASession(t *testing.T) {
	g := testGate(t, epoch)
	w := httptest.NewRecorder()
	g.serve(w, request("GET", tokenPath), webui, &backend{})
	if w.Code != http.StatusFound {
		t.Fatalf("status = %d, want a redirect to log in first", w.Code)
	}
}

// An API token cannot mint another one. Otherwise a leaked token renews itself
// indefinitely and the expiry it carries means nothing (docs/adr/0010).
func TestAnAPITokenCannotMintAnotherOne(t *testing.T) {
	g := testGate(t, epoch)
	raw, _ := g.apiSigner().Issue(Token{Kind: KindAPI, Subject: "yuanying", Service: "sd-webui", Expires: epoch.Add(time.Hour)})

	r := request("GET", tokenPath)
	r.Header.Set("Authorization", "Bearer "+raw)
	w := httptest.NewRecorder()
	g.serve(w, r, webui, &backend{})

	if w.Code == http.StatusOK {
		t.Fatal("a bearer token was allowed to mint a fresh token")
	}
}

// docs/adr/0010: rotation is the only revocation there is, so replacing the
// API signer has to take effect on the next request.
func TestRotatingTheAPIKeyRevokesEveryToken(t *testing.T) {
	g := testGate(t, epoch)
	old, _ := g.apiSigner().Issue(Token{Kind: KindAPI, Subject: "yuanying", Service: "sd-webui", Expires: epoch.Add(time.Hour)})

	fresh := NewSigner([]byte("ffffffffffffffffffffffffffffffff"))
	fresh.now = func() time.Time { return epoch }
	g.setAPISigner(fresh)

	b := &backend{}
	r := request("GET", "http://sd-webui.poissonnerie.dev/")
	r.Header.Set("Authorization", "Bearer "+old)
	w := httptest.NewRecorder()
	g.serve(w, r, webui, b)

	if b.hit {
		t.Fatal("a token signed with the retired key still works")
	}
	if w.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", w.Code)
	}

	// And a session cookie is untouched by the rotation, which is the whole
	// reason the key is a second one.
	session, _ := g.signer.Issue(Token{Kind: KindCookie, Subject: "yuanying", Service: "sd-webui", Expires: epoch.Add(time.Hour)})
	b2 := &backend{}
	r2 := request("GET", "http://sd-webui.poissonnerie.dev/")
	r2.AddCookie(&http.Cookie{Name: cookieName, Value: session})
	g.serve(httptest.NewRecorder(), r2, webui, b2)
	if !b2.hit {
		t.Error("rotating the API key signed a browser out")
	}
}
