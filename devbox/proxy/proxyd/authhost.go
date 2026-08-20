package main

// auth.<zone>: the one host that talks to GitHub.
//
// docs/adr/0007: a GitHub OAuth application has exactly one callback URL and it
// cannot span subdomains, so every login is collected here and the result is
// handed to the service host as a signed, thirty-second token. Publishing a new
// service therefore never involves GitHub's settings page -- which is the
// property that keeps 0004's "adding a service is cheap" true.

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/url"
	"time"
)

const (
	// loginCookieName holds the nonce for one login in progress.
	loginCookieName = "devbox_login"
	// stateTTL is how long a visitor has to get through GitHub.
	stateTTL = 10 * time.Minute
	// handoverTTL is deliberately tiny: this token travels in a URL, so it is
	// in a browser history and possibly a referrer.
	handoverTTL = 30 * time.Second
)

type authHost struct {
	signer   *Signer
	github   *GitHub
	newNonce func() string
}

func newNonce() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		// The only reason this fails is a broken system; refusing to log
		// anybody in is the right answer, and an empty nonce never matches.
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

func (a *authHost) serve(w http.ResponseWriter, r *http.Request, cfg *Config) {
	switch r.URL.Path {
	case "/login":
		a.login(w, r, cfg)
	case "/callback":
		a.callback(w, r, cfg)
	case "/":
		a.index(w, cfg)
	default:
		http.NotFound(w, r)
	}
}

// login starts the round trip, remembering where the visitor was going.
func (a *authHost) login(w http.ResponseWriter, r *http.Request, cfg *Config) {
	svc, dest, err := destination(cfg, r.URL.Query().Get("rd"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	nonce := a.newNonce()
	if nonce == "" {
		http.Error(w, "could not start a login", http.StatusInternalServerError)
		return
	}
	state, err := a.signer.IssueState(nonce, svc.Name, dest, a.signer.now().Add(stateTTL))
	if err != nil {
		http.Error(w, "could not start a login", http.StatusInternalServerError)
		return
	}

	// Matched at the callback: a state parameter obtained somewhere else
	// cannot start a login in this browser.
	http.SetCookie(w, a.loginCookie(nonce, int(stateTTL.Seconds())))
	http.Redirect(w, r, a.github.AuthorizeURL(callbackURI(cfg), state, cfg.OAuthScope()), http.StatusFound)
}

// callback is where GitHub returns. It has a code, a state, and nothing else.
func (a *authHost) callback(w http.ResponseWriter, r *http.Request, cfg *Config) {
	nonce, svcName, dest, err := a.signer.VerifyState(r.URL.Query().Get("state"))
	if err != nil {
		http.Error(w, "this login could not be completed; start again", http.StatusForbidden)
		return
	}

	c, err := r.Cookie(loginCookieName)
	if err != nil || subtle.ConstantTimeCompare([]byte(c.Value), []byte(nonce)) != 1 {
		http.Error(w, "this login did not start in this browser; start again", http.StatusForbidden)
		return
	}
	// Spent, whatever happens next.
	http.SetCookie(w, a.loginCookie("", -1))

	svc, ok := cfg.Lookup(svcName + "." + cfg.Zone)
	if !ok || svc.Auth != AuthRequired {
		http.Error(w, "that service is no longer published", http.StatusNotFound)
		return
	}

	ctx := r.Context()
	token, err := a.github.Exchange(ctx, r.URL.Query().Get("code"), callbackURI(cfg))
	if err != nil {
		http.Error(w, "GitHub would not complete the login", http.StatusBadGateway)
		return
	}
	login, err := a.github.Login(ctx, token)
	if err != nil {
		http.Error(w, "GitHub would not say who you are", http.StatusBadGateway)
		return
	}

	admitted, err := a.github.Admits(ctx, token, login, svc.Viewers)
	if err != nil {
		// Fail closed: an organisation lookup that failed is not a no, but it
		// is certainly not a yes.
		http.Error(w, "could not check whether you are allowed in; try again", http.StatusBadGateway)
		return
	}
	if !admitted {
		// Naming the account is the difference between "fix your account" and
		// "this is broken".
		http.Error(w, fmt.Sprintf("You are signed in to GitHub as %s, who is not on the list for %s.", login, svcName), http.StatusForbidden)
		return
	}

	handover, err := a.signer.Issue(Token{
		Kind:    KindHandover,
		Subject: login,
		Service: svc.Name,
		Path:    dest,
		Expires: a.signer.now().Add(handoverTTL),
	})
	if err != nil {
		http.Error(w, "could not complete the login", http.StatusInternalServerError)
		return
	}

	u := url.URL{
		Scheme:   "https",
		Host:     svc.Name + "." + cfg.Zone,
		Path:     setPath,
		RawQuery: url.Values{"t": {handover}}.Encode(),
	}
	http.Redirect(w, r, u.String(), http.StatusFound)
}

func (a *authHost) index(w http.ResponseWriter, cfg *Config) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintf(w, "This host signs visitors in to services on %s.\n"+
		"There is nothing to see here; go to the service you want.\n", cfg.Zone)
}

func (a *authHost) loginCookie(value string, maxAge int) *http.Cookie {
	return &http.Cookie{
		Name:     loginCookieName,
		Value:    value,
		Path:     "/",
		MaxAge:   maxAge,
		Secure:   true,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	}
}

// destination validates where a login claims to be going. Only a service this
// devbox publishes and that actually asks for a login qualifies, which is what
// keeps /login from being an open redirect.
func destination(cfg *Config, rd string) (Service, string, error) {
	u, err := url.Parse(rd)
	if err != nil {
		return Service{}, "", fmt.Errorf("that is not somewhere I can send you")
	}
	if u.Scheme != "https" || u.Host == "" {
		return Service{}, "", fmt.Errorf("that is not somewhere I can send you")
	}
	svc, ok := cfg.Lookup(u.Host)
	if !ok {
		return Service{}, "", fmt.Errorf("%s is not published from this devbox", u.Host)
	}
	if svc.Auth != AuthRequired {
		return Service{}, "", fmt.Errorf("%s does not ask for a login", u.Host)
	}
	return svc, u.RequestURI(), nil
}

func callbackURI(cfg *Config) string {
	return "https://" + cfg.AuthHost() + "/callback"
}
