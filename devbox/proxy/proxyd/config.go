package main

// The declaration file, and every rule about what may be in it.
//
// docs/adr/0004 makes this file the source of truth and everything else a
// consequence of it; docs/adr/0005 removed the things that used to be generated
// from it, so what is left is this parser and the checks below. `devbox-proxy
// check` is this and nothing else, which is what lets `reload` refuse a broken
// file before signalling anything (docs/adr/0008).

import (
	"errors"
	"fmt"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/goccy/go-yaml"
)

// AuthMode says whether a service asks for a login.
type AuthMode string

const (
	// AuthRequired sends visitors through GitHub before they reach the backend.
	AuthRequired AuthMode = "required"
	// AuthNone publishes the service to anyone who finds it. docs/adr/0007.
	AuthNone AuthMode = "none"
)

// defaultHost is where a backend is when its service does not say: the
// loopback address, which is what every declaration meant before `host` was
// added. docs/adr/0011.
const defaultHost = "127.0.0.1"

// authLabel is the one hostname a service may not claim: it is where the login
// flow lives, and GitHub is configured to send people back to it.
const authLabel = "auth"

// Viewers is who a service admits. Empty means nobody, which is why an
// authenticated service has to list at least one.
type Viewers struct {
	Logins     []string `yaml:"logins"`
	GitHubOrgs []string `yaml:"github_orgs"`
}

func (v Viewers) empty() bool { return len(v.Logins) == 0 && len(v.GitHubOrgs) == 0 }

// Service is one published backend.
type Service struct {
	Name string `yaml:"name"`
	// Host is where the backend listens: a hostname docker's DNS answers
	// for, such as a container name, or an IP address. docs/adr/0011.
	Host    string   `yaml:"host"`
	Port    int      `yaml:"port"`
	Auth    AuthMode `yaml:"auth"`
	Viewers Viewers  `yaml:"viewers"`
}

// Upstream is the address the proxy connects to, with an IPv6 host bracketed.
func (s Service) Upstream() string {
	return net.JoinHostPort(s.Host, strconv.Itoa(s.Port))
}

type defaults struct {
	Auth AuthMode `yaml:"auth"`
}

// Config is a whole declaration file, with defaults already folded into each
// service so that nothing downstream has to consult them again.
type Config struct {
	Zone     string    `yaml:"zone"`
	Defaults defaults  `yaml:"defaults"`
	Services []Service `yaml:"services"`
}

// Load reads and validates a declaration file.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	c, err := Parse(data)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return c, nil
}

// Parse validates a declaration file held in memory. Every problem it can find
// is reported at once: a file with three mistakes should take one run to fix,
// not three.
func Parse(data []byte) (*Config, error) {
	if err := removedKeys(data); err != nil {
		return nil, err
	}

	var c Config
	if err := yaml.UnmarshalWithOptions(data, &c, yaml.Strict()); err != nil {
		return nil, err
	}

	c.applyDefaults()
	if err := c.validate(); err != nil {
		return nil, err
	}
	return &c, nil
}

// applyDefaults folds `defaults` into each service, so that nothing downstream
// has to consult them again. A service that says nothing anywhere asks for a
// login, because that is the safe direction, and is on the loopback address.
func (c *Config) applyDefaults() {
	for i := range c.Services {
		if c.Services[i].Host == "" {
			c.Services[i].Host = defaultHost
		}
		if c.Services[i].Auth == "" {
			c.Services[i].Auth = c.Defaults.Auth
		}
		if c.Services[i].Auth == "" {
			c.Services[i].Auth = AuthRequired
		}
	}
}

// validate checks everything that has to hold about a whole configuration. It
// runs after the overlay has been folded in as well as after parsing, because
// a declaration and an overlay are only valid together (docs/adr/0009) --
// a port collision, for instance, can be created by either one alone.
func (c *Config) validate() error {
	var problems []error
	if strings.TrimSpace(c.Zone) == "" {
		problems = append(problems, errors.New("zone is required: it is the DNS zone every service is published under"))
	}

	seenName := map[string]bool{}
	// A port is only taken on one host: two containers can both listen on
	// :8080. Hostnames are case-insensitive, so the key is lowercased.
	seenPort := map[string]string{}
	for i := range c.Services {
		s := &c.Services[i]

		switch {
		case s.Name == "":
			problems = append(problems, errors.New("a service has no name"))
		case strings.Contains(s.Name, "."):
			problems = append(problems, fmt.Errorf("service %q: a service name is one label, so it cannot contain a dot; namespace in the name instead (gpu-llama)", s.Name))
		case s.Name == authLabel:
			problems = append(problems, fmt.Errorf("service %q: that name is reserved for the login host", s.Name))
		case !validLabel(s.Name):
			problems = append(problems, fmt.Errorf("service %q: a name is lowercase letters, digits and hyphens, not starting or ending with a hyphen, at most 63 characters", s.Name))
		case seenName[s.Name]:
			problems = append(problems, fmt.Errorf("service %q is declared twice", s.Name))
		default:
			seenName[s.Name] = true
		}

		hostOK := true
		if problem := hostProblem(s.Host); problem != "" {
			hostOK = false
			problems = append(problems, fmt.Errorf("service %q: host %q %s", s.Name, s.Host, problem))
		}

		key := strings.ToLower(s.Upstream())
		if s.Port < 1 || s.Port > 65535 {
			problems = append(problems, fmt.Errorf("service %q: port %d is not a port a backend can be listening on", s.Name, s.Port))
		} else if !hostOK {
			// Already reported; a collision on a host that is not one would
			// only be noise.
		} else if other, dup := seenPort[key]; dup {
			problems = append(problems, fmt.Errorf("port %d on %s is claimed by both %q and %q", s.Port, s.Host, other, s.Name))
		} else {
			seenPort[key] = s.Name
		}

		switch s.Auth {
		case AuthRequired:
			// Listing nobody here is not an error: the guest list can also
			// come from the overlay in the state directory (docs/adr/0009).
			// Config.Unreachable reports what nobody can reach once both have
			// been read.
		case AuthNone:
			if !s.Viewers.empty() {
				problems = append(problems, fmt.Errorf("service %q: auth is none, so the viewers listed would be ignored", s.Name))
			}
		default:
			problems = append(problems, fmt.Errorf("service %q: auth is %q, but it is either \"required\" or \"none\"", s.Name, s.Auth))
		}
	}

	if len(problems) > 0 {
		return errors.Join(problems...)
	}
	return nil
}

// removedKeys turns "unknown field" into an explanation. These four were load
// bearing until docs/adr/0005, so a declaration file that still carries them is
// not a typo -- it is one that predates the change and needs a specific edit.
func removedKeys(data []byte) error {
	var probe struct {
		TeamDomain any `yaml:"team_domain"`
		Origin     any `yaml:"origin"`
		Services   []struct {
			Aud     any `yaml:"aud"`
			Viewers struct {
				Emails any `yaml:"emails"`
			} `yaml:"viewers"`
		} `yaml:"services"`
	}
	// Not strict: this pass is only looking for keys that were removed, and
	// anything else it does not recognise is the next decode's business.
	if err := yaml.Unmarshal(data, &probe); err != nil {
		return nil
	}

	var problems []error
	if probe.TeamDomain != nil {
		problems = append(problems, errors.New(`team_domain was removed: the login no longer goes through Cloudflare Access (docs/adr/0005)`))
	}
	if probe.Origin != nil {
		problems = append(problems, errors.New(`origin was removed: one wildcard AAAA record is placed by hand, so nothing here needs the address (docs/adr/0005)`))
	}
	for _, s := range probe.Services {
		if s.Aud != nil {
			problems = append(problems, errors.New(`aud was removed: there is no Access application to have an audience tag (docs/adr/0005)`))
			break
		}
	}
	for _, s := range probe.Services {
		if s.Viewers.Emails != nil {
			problems = append(problems, errors.New(`viewers.emails became viewers.logins: viewers are GitHub account names now, not email addresses (docs/adr/0007)`))
			break
		}
	}
	if len(problems) > 0 {
		return errors.Join(problems...)
	}
	return nil
}

// hostProblem says what is wrong with a service's host, or "" when nothing is.
//
// A host is where to connect and nothing else. The port has a key of its own
// and the scheme is always http, so a host that carries either is a mistake
// worth naming rather than a string to pass to the resolver and fail on later.
func hostProblem(h string) string {
	switch {
	case strings.TrimSpace(h) == "":
		return "is blank; leave host out for 127.0.0.1"
	case strings.Contains(h, "://"):
		return "has a scheme; write only the host, the proxy always speaks http to it"
	case strings.ContainsAny(h, "[]"):
		return "has brackets; write an IPv6 address without them"
	case net.ParseIP(h) != nil:
		return ""
	case strings.Count(h, ":") == 1:
		return "carries a port; the port goes in `port`"
	case strings.Contains(h, ":"):
		return "is not an IP address (a zone such as %eth0 is not accepted either)"
	case len(h) > 253:
		return "is longer than a hostname can be"
	}
	for _, label := range strings.Split(h, ".") {
		if label == "" {
			return "has an empty label; a hostname has no leading, trailing or doubled dots"
		}
		if len(label) > 63 {
			return "has a label longer than 63 characters"
		}
		for _, r := range label {
			switch {
			case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			default:
				return "is neither an IP address nor a hostname: a hostname is letters, digits, hyphens and underscores, in labels separated by dots"
			}
		}
	}
	return ""
}

func validLabel(s string) bool {
	if s == "" || len(s) > 63 {
		return false
	}
	if s[0] == '-' || s[len(s)-1] == '-' {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-':
		default:
			return false
		}
	}
	return true
}

// AuthHost is where every login flow happens. docs/adr/0007.
func (c *Config) AuthHost() string { return authLabel + "." + c.Zone }

// Hostnames is every name this devbox answers to, sorted. It is the allow-list
// certmagic consults before asking Let's Encrypt for anything: a wildcard AAAA
// record means any label reaches us, and only these may cost a certificate.
func (c *Config) Hostnames() []string {
	names := make([]string, 0, len(c.Services)+1)
	names = append(names, c.AuthHost())
	for _, s := range c.Services {
		names = append(names, s.Name+"."+c.Zone)
	}
	sort.Strings(names)
	return names
}

// Lookup finds the service a request is for. It does not match the auth host,
// which is not a service and has no backend.
func (c *Config) Lookup(host string) (Service, bool) {
	host = normaliseHost(host)
	if host == "" {
		return Service{}, false
	}
	for _, s := range c.Services {
		if host == s.Name+"."+c.Zone {
			return s, true
		}
	}
	return Service{}, false
}

// Allows reports whether a hostname is one we are willing to serve, the auth
// host included.
func (c *Config) Allows(host string) bool {
	host = normaliseHost(host)
	if host == "" {
		return false
	}
	if host == c.AuthHost() {
		return true
	}
	_, ok := c.Lookup(host)
	return ok
}

// normaliseHost strips the port a Host header may carry and lowercases the
// rest, because hostnames are case-insensitive and browsers do not always agree
// on which case to send.
func normaliseHost(host string) string {
	if i := strings.LastIndex(host, ":"); i >= 0 && !strings.Contains(host[i+1:], ":") {
		host = host[:i]
	}
	return strings.ToLower(strings.TrimSuffix(host, "."))
}

// OAuthScope is what to ask GitHub for. A login comes back without any scope
// at all, so nothing is requested unless some service is gated on an
// organisation. docs/adr/0007.
func (c *Config) OAuthScope() string {
	for _, s := range c.Services {
		if len(s.Viewers.GitHubOrgs) > 0 {
			return "read:org"
		}
	}
	return ""
}
