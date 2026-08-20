package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

const authTestConfig = `
zone: poissonnerie.dev
services:
  - name: sd-webui
    port: 7860
    auth: required
    viewers:
      logins:
        - yuanying
  - name: docs
    port: 8080
    auth: none
`

func testAuthHost(t *testing.T, f *fakeGitHub) (*authHost, *Config) {
	t.Helper()
	cfg, err := Parse([]byte(authTestConfig))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	return &authHost{
		signer:   testSigner(t, epoch),
		github:   newTestGitHub(t, f),
		newNonce: func() string { return "the-nonce" },
	}, cfg
}

func authRequest(target string) *http.Request {
	r := httptest.NewRequest("GET", target, nil)
	r.Host = "auth.poissonnerie.dev"
	return r
}

func TestLoginSendsThemToGitHub(t *testing.T) {
	a, cfg := testAuthHost(t, &fakeGitHub{code: "c", token: "t", login: "yuanying"})
	w := httptest.NewRecorder()
	rd := "https://sd-webui.poissonnerie.dev/generate?seed=1"
	a.serve(w, authRequest("/login?rd="+url.QueryEscape(rd)), cfg)

	if w.Code != http.StatusFound {
		t.Fatalf("status = %d, want 302; body %s", w.Code, w.Body)
	}
	loc, err := url.Parse(w.Header().Get("Location"))
	if err != nil {
		t.Fatalf("Location: %v", err)
	}
	q := loc.Query()
	if q.Get("client_id") != "client-id" {
		t.Errorf("client_id = %q", q.Get("client_id"))
	}
	if got := q.Get("redirect_uri"); got != "https://auth.poissonnerie.dev/callback" {
		t.Errorf("redirect_uri = %q", got)
	}
	state := q.Get("state")
	if state == "" {
		t.Fatal("no state parameter")
	}
	nonce, svc, path, err := a.signer.VerifyState(state)
	if err != nil {
		t.Fatalf("the state parameter does not verify: %v", err)
	}
	if nonce != "the-nonce" || svc != "sd-webui" || path != "/generate?seed=1" {
		t.Errorf("state carries nonce=%q svc=%q path=%q", nonce, svc, path)
	}

	// The nonce is also dropped as a cookie, so a state parameter obtained
	// elsewhere cannot start a login in this browser.
	cookies := w.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Value != "the-nonce" {
		t.Fatalf("cookies = %+v, want the nonce", cookies)
	}
	if !cookies[0].HttpOnly || !cookies[0].Secure || cookies[0].Domain != "" {
		t.Errorf("the login cookie is not host-only, Secure and HttpOnly: %+v", cookies[0])
	}
}

func TestLoginRefusesSomewhereElse(t *testing.T) {
	for name, rd := range map[string]string{
		"an undeclared name":   "https://nope.poissonnerie.dev/",
		"another zone":         "https://sd-webui.oeilvert.dev/",
		"somewhere off-site":   "https://evil.example.com/",
		"the auth host itself": "https://auth.poissonnerie.dev/login",
		"not a URL":            "::::",
		"missing":              "",
	} {
		t.Run(name, func(t *testing.T) {
			a, cfg := testAuthHost(t, &fakeGitHub{})
			w := httptest.NewRecorder()
			a.serve(w, authRequest("/login?rd="+url.QueryEscape(rd)), cfg)

			if w.Code == http.StatusFound {
				t.Errorf("it redirected to %q", w.Header().Get("Location"))
			}
		})
	}
}

// A service published with auth: none has no login to offer.
func TestLoginRefusesAPublicService(t *testing.T) {
	a, cfg := testAuthHost(t, &fakeGitHub{})
	w := httptest.NewRecorder()
	a.serve(w, authRequest("/login?rd="+url.QueryEscape("https://docs.poissonnerie.dev/")), cfg)
	if w.Code == http.StatusFound {
		t.Errorf("it started a login for a service that does not need one")
	}
}

// The whole round trip: /login, then GitHub coming back to /callback.
func completeLogin(t *testing.T, a *authHost, cfg *Config, f *fakeGitHub, rd string) *httptest.ResponseRecorder {
	t.Helper()
	first := httptest.NewRecorder()
	a.serve(first, authRequest("/login?rd="+url.QueryEscape(rd)), cfg)
	if first.Code != http.StatusFound {
		t.Fatalf("/login returned %d: %s", first.Code, first.Body)
	}
	loc, _ := url.Parse(first.Header().Get("Location"))
	state := loc.Query().Get("state")

	back := authRequest("/callback?code=" + f.code + "&state=" + url.QueryEscape(state))
	for _, c := range first.Result().Cookies() {
		back.AddCookie(c)
	}
	w := httptest.NewRecorder()
	a.serve(w, back, cfg)
	return w
}

func TestCallbackHandsOverToTheService(t *testing.T) {
	f := &fakeGitHub{code: "the-code", token: "the-token", login: "yuanying"}
	a, cfg := testAuthHost(t, f)
	w := completeLogin(t, a, cfg, f, "https://sd-webui.poissonnerie.dev/generate?seed=1")

	if w.Code != http.StatusFound {
		t.Fatalf("status = %d, want 302; body %s", w.Code, w.Body)
	}
	loc, err := url.Parse(w.Header().Get("Location"))
	if err != nil {
		t.Fatalf("Location: %v", err)
	}
	if loc.Host != "sd-webui.poissonnerie.dev" || loc.Path != setPath {
		t.Fatalf("handed over to %s", loc)
	}
	tok, err := a.signer.Verify(loc.Query().Get("t"), KindHandover, "sd-webui")
	if err != nil {
		t.Fatalf("the handover token does not verify: %v", err)
	}
	if tok.Subject != "yuanying" {
		t.Errorf("Subject = %q", tok.Subject)
	}
	if tok.Path != "/generate?seed=1" {
		t.Errorf("Path = %q, lost where they were going", tok.Path)
	}
	// The handover must be short-lived; it travels in a URL.
	if d := tok.Expires.Sub(epoch); d > time.Minute {
		t.Errorf("the handover token lives for %v", d)
	}
}

func TestCallbackRefusesSomebodyNotListed(t *testing.T) {
	f := &fakeGitHub{code: "the-code", token: "the-token", login: "stranger"}
	a, cfg := testAuthHost(t, f)
	w := completeLogin(t, a, cfg, f, "https://sd-webui.poissonnerie.dev/")

	if w.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", w.Code)
	}
	// Saying who they are logged in as is the difference between "fix your
	// account" and "this is broken".
	if !strings.Contains(w.Body.String(), "stranger") {
		t.Errorf("the refusal does not say who they are: %s", w.Body)
	}
}

func TestCallbackNeedsTheMatchingCookie(t *testing.T) {
	f := &fakeGitHub{code: "the-code", token: "the-token", login: "yuanying"}
	a, cfg := testAuthHost(t, f)

	first := httptest.NewRecorder()
	a.serve(first, authRequest("/login?rd="+url.QueryEscape("https://sd-webui.poissonnerie.dev/")), cfg)
	loc, _ := url.Parse(first.Header().Get("Location"))
	state := loc.Query().Get("state")

	t.Run("no cookie at all", func(t *testing.T) {
		w := httptest.NewRecorder()
		a.serve(w, authRequest("/callback?code=the-code&state="+url.QueryEscape(state)), cfg)
		if w.Code == http.StatusFound {
			t.Error("a login completed without the cookie it started with")
		}
	})

	t.Run("somebody else's cookie", func(t *testing.T) {
		r := authRequest("/callback?code=the-code&state=" + url.QueryEscape(state))
		r.AddCookie(&http.Cookie{Name: loginCookieName, Value: "another-nonce"})
		w := httptest.NewRecorder()
		a.serve(w, r, cfg)
		if w.Code == http.StatusFound {
			t.Error("a mismatched nonce completed a login")
		}
	})
}

func TestCallbackRefusesABadState(t *testing.T) {
	f := &fakeGitHub{code: "the-code", token: "the-token", login: "yuanying"}
	a, cfg := testAuthHost(t, f)

	for name, state := range map[string]string{
		"missing":  "",
		"nonsense": "garbage",
		"tampered": "eyJrIjoicyJ9.AAAA",
	} {
		t.Run(name, func(t *testing.T) {
			r := authRequest("/callback?code=the-code&state=" + url.QueryEscape(state))
			r.AddCookie(&http.Cookie{Name: loginCookieName, Value: "the-nonce"})
			w := httptest.NewRecorder()
			a.serve(w, r, cfg)
			if w.Code == http.StatusFound {
				t.Error("it completed a login")
			}
		})
	}
}

func TestCallbackRefusesABadCode(t *testing.T) {
	f := &fakeGitHub{code: "the-code", token: "the-token", login: "yuanying"}
	a, cfg := testAuthHost(t, f)

	first := httptest.NewRecorder()
	a.serve(first, authRequest("/login?rd="+url.QueryEscape("https://sd-webui.poissonnerie.dev/")), cfg)
	loc, _ := url.Parse(first.Header().Get("Location"))

	r := authRequest("/callback?code=wrong&state=" + url.QueryEscape(loc.Query().Get("state")))
	for _, c := range first.Result().Cookies() {
		r.AddCookie(c)
	}
	w := httptest.NewRecorder()
	a.serve(w, r, cfg)

	if w.Code == http.StatusFound {
		t.Error("a bad code completed a login")
	}
}

// Between /login and /callback the declaration file may have been reloaded.
func TestCallbackRefusesAServiceThatIsGone(t *testing.T) {
	f := &fakeGitHub{code: "the-code", token: "the-token", login: "yuanying"}
	a, cfg := testAuthHost(t, f)

	first := httptest.NewRecorder()
	a.serve(first, authRequest("/login?rd="+url.QueryEscape("https://sd-webui.poissonnerie.dev/")), cfg)
	loc, _ := url.Parse(first.Header().Get("Location"))

	shrunk, err := Parse([]byte("zone: poissonnerie.dev\nservices: []\n"))
	if err != nil {
		t.Fatal(err)
	}
	r := authRequest("/callback?code=the-code&state=" + url.QueryEscape(loc.Query().Get("state")))
	for _, c := range first.Result().Cookies() {
		r.AddCookie(c)
	}
	w := httptest.NewRecorder()
	a.serve(w, r, shrunk)

	if w.Code == http.StatusFound {
		t.Error("it handed over to a service that is no longer declared")
	}
}

func TestScopeIsRequestedOnlyWhenOrgsAreUsed(t *testing.T) {
	f := &fakeGitHub{code: "c", token: "t", login: "yuanying"}
	a, cfg := testAuthHost(t, f)

	w := httptest.NewRecorder()
	a.serve(w, authRequest("/login?rd="+url.QueryEscape("https://sd-webui.poissonnerie.dev/")), cfg)
	loc, _ := url.Parse(w.Header().Get("Location"))
	if got := loc.Query().Get("scope"); got != "" {
		t.Errorf("scope = %q, want none for a logins-only declaration", got)
	}

	withOrg, err := Parse([]byte("zone: poissonnerie.dev\nservices:\n  - name: sd-webui\n    port: 7860\n    auth: required\n    viewers:\n      github_orgs: [acme]\n"))
	if err != nil {
		t.Fatal(err)
	}
	w = httptest.NewRecorder()
	a.serve(w, authRequest("/login?rd="+url.QueryEscape("https://sd-webui.poissonnerie.dev/")), withOrg)
	loc, _ = url.Parse(w.Header().Get("Location"))
	if got := loc.Query().Get("scope"); got != "read:org" {
		t.Errorf("scope = %q, want read:org", got)
	}
}

func TestAuthHostIndexSaysWhatItIs(t *testing.T) {
	a, cfg := testAuthHost(t, &fakeGitHub{})
	w := httptest.NewRecorder()
	a.serve(w, authRequest("/"), cfg)
	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", w.Code)
	}
}
