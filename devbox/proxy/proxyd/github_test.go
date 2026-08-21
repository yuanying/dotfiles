package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeGitHub is enough of GitHub to exercise the exchange and the two lookups.
type fakeGitHub struct {
	code   string            // the one code it will trade
	token  string            // what it trades the code for
	login  string            // who that token belongs to
	orgs   map[string]string // org -> membership state
	failed bool              // set when it is asked for something it refuses

	tokenHits int
}

func (f *fakeGitHub) server(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()

	mux.HandleFunc("/login/oauth/access_token", func(w http.ResponseWriter, r *http.Request) {
		f.tokenHits++
		if err := r.ParseForm(); err != nil {
			http.Error(w, "bad form", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if r.PostFormValue("code") != f.code {
			// GitHub answers 200 with an error body, which is the trap worth
			// covering: a naive client reads this as success.
			json.NewEncoder(w).Encode(map[string]string{
				"error":             "bad_verification_code",
				"error_description": "The code passed is incorrect or expired.",
			})
			return
		}
		json.NewEncoder(w).Encode(map[string]string{
			"access_token": f.token,
			"token_type":   "bearer",
		})
	})

	mux.HandleFunc("/user", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+f.token {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"login": f.login, "id": 1})
	})

	mux.HandleFunc("/user/memberships/orgs/", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+f.token {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		org := strings.TrimPrefix(r.URL.Path, "/user/memberships/orgs/")
		state, ok := f.orgs[org]
		if !ok {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"state": state})
	})

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		f.failed = true
		http.Error(w, "unexpected "+r.URL.Path, http.StatusTeapot)
	})

	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func newTestGitHub(t *testing.T, f *fakeGitHub) *GitHub {
	t.Helper()
	srv := f.server(t)
	g := NewGitHub("client-id", "client-secret")
	g.authorizeURL = srv.URL + "/login/oauth/authorize"
	g.tokenURL = srv.URL + "/login/oauth/access_token"
	g.apiBase = srv.URL
	return g
}

func TestAuthorizeURL(t *testing.T) {
	g := NewGitHub("client-id", "client-secret")
	raw := g.AuthorizeURL("https://auth.z.dev/callback", "the-state", "read:org")
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("AuthorizeURL produced %q: %v", raw, err)
	}
	q := u.Query()
	for key, want := range map[string]string{
		"client_id":    "client-id",
		"redirect_uri": "https://auth.z.dev/callback",
		"state":        "the-state",
		"scope":        "read:org",
	} {
		if got := q.Get(key); got != want {
			t.Errorf("%s = %q, want %q", key, got, want)
		}
	}
	if u.Host != "github.com" {
		t.Errorf("host = %q, want github.com", u.Host)
	}
	// The secret has no business being in a URL the browser follows.
	if strings.Contains(raw, "client-secret") {
		t.Error("the client secret is in the authorize URL")
	}
}

func TestExchangeAndLogin(t *testing.T) {
	f := &fakeGitHub{code: "the-code", token: "the-token", login: "yuanying"}
	g := newTestGitHub(t, f)

	token, err := g.Exchange(context.Background(), "the-code", "https://auth.z.dev/callback")
	if err != nil {
		t.Fatalf("Exchange: %v", err)
	}
	if token != "the-token" {
		t.Fatalf("Exchange = %q", token)
	}

	login, err := g.Login(context.Background(), token)
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	if login != "yuanying" {
		t.Errorf("Login = %q, want yuanying", login)
	}
	if f.failed {
		t.Error("an unexpected endpoint was called")
	}
}

// GitHub answers a bad code with HTTP 200 and an error in the body.
func TestExchangeRejectsABadCode(t *testing.T) {
	f := &fakeGitHub{code: "the-code", token: "the-token", login: "yuanying"}
	g := newTestGitHub(t, f)

	if _, err := g.Exchange(context.Background(), "wrong-code", "https://auth.z.dev/callback"); err == nil {
		t.Fatal("Exchange accepted a bad code")
	} else if !strings.Contains(err.Error(), "bad_verification_code") {
		t.Errorf("error %q does not carry what GitHub said", err)
	}
}

func TestLoginRejectsABadToken(t *testing.T) {
	f := &fakeGitHub{code: "the-code", token: "the-token", login: "yuanying"}
	g := newTestGitHub(t, f)
	if _, err := g.Login(context.Background(), "not-the-token"); err == nil {
		t.Fatal("Login accepted a bad token")
	}
}

func TestAdmitsByLogin(t *testing.T) {
	f := &fakeGitHub{code: "c", token: "t", login: "yuanying"}
	g := newTestGitHub(t, f)
	v := Viewers{Logins: []string{"someone", "yuanying"}}

	ok, err := g.Admits(context.Background(), "t", "yuanying", v)
	if err != nil {
		t.Fatalf("Admits: %v", err)
	}
	if !ok {
		t.Error("a listed login was refused")
	}
	// A listed login needs no API call at all.
	if f.failed {
		t.Error("an unexpected endpoint was called")
	}
}

func TestRefusesAnUnlistedLogin(t *testing.T) {
	f := &fakeGitHub{code: "c", token: "t", login: "stranger"}
	g := newTestGitHub(t, f)

	ok, err := g.Admits(context.Background(), "t", "stranger", Viewers{Logins: []string{"yuanying"}})
	if err != nil {
		t.Fatalf("Admits: %v", err)
	}
	if ok {
		t.Error("an unlisted login was admitted")
	}
}

func TestAdmitsByOrgMembership(t *testing.T) {
	f := &fakeGitHub{code: "c", token: "t", login: "stranger", orgs: map[string]string{"acme": "active"}}
	g := newTestGitHub(t, f)

	ok, err := g.Admits(context.Background(), "t", "stranger", Viewers{GitHubOrgs: []string{"acme"}})
	if err != nil {
		t.Fatalf("Admits: %v", err)
	}
	if !ok {
		t.Error("an active member of a listed org was refused")
	}
}

// An invitation that has not been accepted is not membership.
func TestRefusesAPendingMembership(t *testing.T) {
	f := &fakeGitHub{code: "c", token: "t", login: "stranger", orgs: map[string]string{"acme": "pending"}}
	g := newTestGitHub(t, f)

	ok, err := g.Admits(context.Background(), "t", "stranger", Viewers{GitHubOrgs: []string{"acme"}})
	if err != nil {
		t.Fatalf("Admits: %v", err)
	}
	if ok {
		t.Error("a pending invitation was treated as membership")
	}
}

func TestRefusesANonMember(t *testing.T) {
	f := &fakeGitHub{code: "c", token: "t", login: "stranger", orgs: map[string]string{}}
	g := newTestGitHub(t, f)

	ok, err := g.Admits(context.Background(), "t", "stranger", Viewers{GitHubOrgs: []string{"acme"}})
	if err != nil {
		t.Fatalf("Admits returned an error for a plain non-member: %v", err)
	}
	if ok {
		t.Error("a non-member was admitted")
	}
}

func TestAdmitsNobodyWhenNobodyIsListed(t *testing.T) {
	f := &fakeGitHub{code: "c", token: "t", login: "yuanying"}
	g := newTestGitHub(t, f)

	ok, err := g.Admits(context.Background(), "t", "yuanying", Viewers{})
	if err != nil {
		t.Fatalf("Admits: %v", err)
	}
	if ok {
		t.Error("an empty viewers list admitted somebody")
	}
}

// GitHub being down must not admit anyone. Fail closed, as 0003 had it.
func TestOrgLookupFailureIsNotAdmission(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)
	g := NewGitHub("id", "secret")
	g.apiBase = srv.URL

	ok, err := g.Admits(context.Background(), "t", "stranger", Viewers{GitHubOrgs: []string{"acme"}})
	if ok {
		t.Error("a failing org lookup admitted somebody")
	}
	if err == nil {
		t.Error("a failing org lookup was reported as a clean refusal")
	}
}

func TestScopeFollowsTheDeclaration(t *testing.T) {
	for _, tc := range []struct{ name, yaml, want string }{
		{
			name: "logins only needs nothing",
			yaml: "zone: z.dev\nservices:\n  - name: a\n    port: 1\n    auth: required\n    viewers:\n      logins: [someone]\n",
			want: "",
		},
		{
			name: "an org needs read:org",
			yaml: "zone: z.dev\nservices:\n  - name: a\n    port: 1\n    auth: required\n    viewers:\n      github_orgs: [acme]\n",
			want: "read:org",
		},
		{
			name: "nothing published needs nothing",
			yaml: "zone: z.dev\nservices: []\n",
			want: "",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, err := Parse([]byte(tc.yaml))
			if err != nil {
				t.Fatalf("Parse: %v", err)
			}
			if got := c.OAuthScope(); got != tc.want {
				t.Errorf("OAuthScope() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestLoadGitHubCredentials(t *testing.T) {
	path := filepath.Join(t.TempDir(), "github.yaml")
	body := "client_id: Iv1.deadbeef\nclient_secret: s3cr3t\n"
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	creds, err := LoadGitHubCredentials(path)
	if err != nil {
		t.Fatalf("LoadGitHubCredentials: %v", err)
	}
	if creds.ClientID != "Iv1.deadbeef" || creds.ClientSecret != "s3cr3t" {
		t.Errorf("got %+v", creds)
	}
}

func TestGitHubCredentialsMustBePrivate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "github.yaml")
	if err := os.WriteFile(path, []byte("client_id: a\nclient_secret: b\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadGitHubCredentials(path); err == nil {
		t.Fatal("a world-readable client secret was accepted")
	}
}

func TestGitHubCredentialsMustBeComplete(t *testing.T) {
	for _, body := range []string{
		"client_id: a\n",
		"client_secret: b\n",
		"",
	} {
		path := filepath.Join(t.TempDir(), "github.yaml")
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadGitHubCredentials(path); err == nil {
			t.Errorf("accepted %q", body)
		}
	}
}
