package main

// What happens to one request for one published service.
//
// docs/adr/0007: the check runs here rather than at an edge, so it holds on
// every path a request can take -- through the wildcard DNS record, or straight
// at the devbox's IPv6 address. There is no back door of the kind 0003 had to
// close separately, because there is no front door that knows anything this one
// does not.

import (
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	// authPrefix is reserved on every service host and never forwarded.
	authPrefix = "/_devbox-auth/"
	// setPath spends a handover token from the auth host for a cookie here.
	setPath = authPrefix + "set"
	// logoutPath drops the cookie. It cannot revoke anything -- rotating the
	// signing key is the only revocation there is -- but it ends this session
	// in this browser.
	logoutPath = authPrefix + "logout"

	cookieName = "devbox_session"

	// userHeader tells the backend who this is. It is stripped from every
	// incoming request first, so a backend that trusts it is not trusting
	// whoever set it.
	userHeader = "X-Devbox-User"
)

type gate struct {
	signer    *Signer
	authHost  string
	cookieTTL time.Duration
}

// serve either forwards the request to backend or does something else with it.
func (g *gate) serve(w http.ResponseWriter, r *http.Request, svc Service, backend http.Handler) {
	// Whatever arrives claiming to be an identity is not one.
	r.Header.Del(userHeader)

	if strings.HasPrefix(r.URL.Path, authPrefix) {
		switch r.URL.Path {
		case setPath:
			g.spendHandover(w, r, svc)
		case logoutPath:
			g.logout(w, r)
		default:
			http.NotFound(w, r)
		}
		return
	}

	if svc.Auth == AuthNone {
		backend.ServeHTTP(w, r)
		return
	}

	tok, err := g.session(r, svc)
	if err != nil {
		// Not an error to show anyone: a visitor without a good cookie is a
		// visitor who needs to log in.
		g.toLogin(w, r)
		return
	}

	r.Header.Set(userHeader, tok.Subject)
	backend.ServeHTTP(w, r)
}

func (g *gate) session(r *http.Request, svc Service) (*Token, error) {
	c, err := r.Cookie(cookieName)
	if err != nil {
		return nil, err
	}
	return g.signer.Verify(c.Value, KindCookie, svc.Name)
}

// toLogin sends the visitor to the auth host, remembering where they were
// going. docs/adr/0007: one host collects every login, because a GitHub OAuth
// application has exactly one callback URL.
func (g *gate) toLogin(w http.ResponseWriter, r *http.Request) {
	target := "https://" + r.Host + r.URL.RequestURI()
	u := url.URL{
		Scheme:   "https",
		Host:     g.authHost,
		Path:     "/login",
		RawQuery: url.Values{"rd": {target}}.Encode(),
	}
	http.Redirect(w, r, u.String(), http.StatusFound)
}

// spendHandover trades the short-lived token the auth host issued for a session
// cookie on this host.
func (g *gate) spendHandover(w http.ResponseWriter, r *http.Request, svc Service) {
	tok, err := g.signer.Verify(r.URL.Query().Get("t"), KindHandover, svc.Name)
	if err != nil {
		http.Error(w, "this login could not be completed", http.StatusForbidden)
		return
	}

	raw, err := g.signer.Issue(Token{
		Kind:    KindCookie,
		Subject: tok.Subject,
		Service: svc.Name,
		Expires: g.signer.now().Add(g.cookieTTL),
	})
	if err != nil {
		http.Error(w, "could not issue a session", http.StatusInternalServerError)
		return
	}
	http.SetCookie(w, g.cookie(raw, int(g.cookieTTL.Seconds())))

	dest := tok.Path
	if dest == "" {
		dest = "/"
	}
	http.Redirect(w, r, dest, http.StatusFound)
}

func (g *gate) logout(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, g.cookie("", -1))
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write([]byte("Signed out of this service in this browser.\n"))
}

// cookie is host-only on purpose: no Domain attribute, so it is never offered
// to another name in the zone. A wildcard cookie would be readable by anything
// published there, including a service deliberately left open (docs/adr/0007).
func (g *gate) cookie(value string, maxAge int) *http.Cookie {
	return &http.Cookie{
		Name:     cookieName,
		Value:    value,
		Path:     "/",
		MaxAge:   maxAge,
		Secure:   true,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	}
}
