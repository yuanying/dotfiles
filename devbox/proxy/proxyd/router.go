package main

// Which host gets which handler, and how that mapping is replaced.
//
// docs/adr/0008: reload swaps the whole table behind a pointer rather than
// mutating it, so a request that has already been routed finishes against the
// configuration it was routed by, listeners stay bound, and nothing in flight
// is dropped. That is what makes publishing a second service invisible to the
// first one, which matters when the first one has been streaming a response
// for several minutes.

import (
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"sync/atomic"
	"time"
)

// routes is one immutable snapshot: a declaration and the backends built from
// it. Replaced wholesale, never edited.
type routes struct {
	cfg      *Config
	backends map[string]http.Handler
}

// Router serves every request the proxy accepts.
type Router struct {
	current atomic.Pointer[routes]

	gate *gate
	auth *authHost

	// newBackend builds the handler for one service, so the tests can put
	// something other than a network connection behind it.
	newBackend func(s Service) http.Handler
}

// NewRouter returns a router that proxies to wherever each service says its
// backend is: 127.0.0.1 unless it names a host (docs/adr/0011).
func NewRouter(signer, apiSigner *Signer, github *GitHub, authHostName string, cookieTTL, apiTTL time.Duration) *Router {
	rt := &Router{
		gate: &gate{
			signer:    signer,
			authHost:  authHostName,
			cookieTTL: cookieTTL,
			apiTTL:    apiTTL,
		},
		auth: &authHost{
			signer:   signer,
			github:   github,
			newNonce: newNonce,
		},
		newBackend: func(s Service) http.Handler { return reverseProxy(s.Upstream()) },
	}
	rt.SetAPISigner(apiSigner)
	return rt
}

// SetAPISigner puts an API signing key into force. reload calls it with
// whatever is on disk at the time, so retiring every API token is deleting the
// key file and reloading -- and a request already in flight finishes, the same
// property the routing table has (docs/adr/0008, docs/adr/0010).
func (rt *Router) SetAPISigner(s *Signer) { rt.gate.setAPISigner(s) }

// Set puts a declaration into force. Everything derived from it is rebuilt
// here, once, rather than per request.
func (rt *Router) Set(cfg *Config) {
	backends := make(map[string]http.Handler, len(cfg.Services))
	for _, s := range cfg.Services {
		backends[s.Name] = rt.newBackend(s)
	}
	rt.current.Store(&routes{cfg: cfg, backends: backends})
}

// Config is the declaration currently in force.
func (rt *Router) Config() *Config {
	cur := rt.current.Load()
	if cur == nil {
		return nil
	}
	return cur.cfg
}

func (rt *Router) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	cur := rt.current.Load()
	if cur == nil {
		http.Error(w, "the proxy has no configuration", http.StatusServiceUnavailable)
		return
	}

	host := normaliseHost(r.Host)
	if host == "" {
		http.NotFound(w, r)
		return
	}

	if host == cur.cfg.AuthHost() {
		rt.auth.serve(w, r, cur.cfg)
		return
	}

	// A wildcard AAAA record puts every label in the zone here, and the IPv6
	// address takes anything at all. Only what is declared is answered.
	svc, ok := cur.cfg.Lookup(host)
	if !ok {
		http.NotFound(w, r)
		return
	}
	backend, ok := cur.backends[svc.Name]
	if !ok {
		http.Error(w, "no backend for this service", http.StatusServiceUnavailable)
		return
	}

	rt.gate.serve(w, r, svc, backend)
}

// reverseProxy forwards to a backend at upstream, a host:port. The host is
// resolved when a connection is made, not here, so a container that has been
// recreated with a new address is found again without a reload.
func reverseProxy(upstream string) http.Handler {
	target := &url.URL{Scheme: "http", Host: upstream}
	return &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			// Backends that build absolute links need the name the visitor
			// used, not the address the proxy connected to.
			pr.Out.Host = pr.In.Host
			pr.SetXForwarded()
		},
		// Flush as it arrives. The main workload streams tokens for minutes,
		// and buffering that is the difference between working and appearing
		// to hang.
		FlushInterval: -1,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("proxy: %s %s: %v", r.Host, r.URL.Path, err)
			http.Error(w, "the service behind this name is not answering", http.StatusBadGateway)
		},
	}
}
