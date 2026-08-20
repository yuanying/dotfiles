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
	"os"
	"sort"
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
	Name    string   `yaml:"name"`
	Port    int      `yaml:"port"`
	Auth    AuthMode `yaml:"auth"`
	Viewers Viewers  `yaml:"viewers"`
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

	var problems []error
	if strings.TrimSpace(c.Zone) == "" {
		problems = append(problems, errors.New("zone is required: it is the DNS zone every service is published under"))
	}

	seenName := map[string]bool{}
	seenPort := map[int]string{}
	for i := range c.Services {
		s := &c.Services[i]

		if s.Auth == "" {
			s.Auth = c.Defaults.Auth
		}
		if s.Auth == "" {
			s.Auth = AuthRequired
		}

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

		if s.Port < 1 || s.Port > 65535 {
			problems = append(problems, fmt.Errorf("service %q: port %d is not a port a backend can be listening on", s.Name, s.Port))
		} else if other, dup := seenPort[s.Port]; dup {
			problems = append(problems, fmt.Errorf("port %d is claimed by both %q and %q", s.Port, other, s.Name))
		} else {
			seenPort[s.Port] = s.Name
		}

		switch s.Auth {
		case AuthRequired:
			if s.Viewers.empty() {
				problems = append(problems, fmt.Errorf("service %q: auth is required but no viewer is listed, which would lock out everyone; add viewers.logins or viewers.github_orgs", s.Name))
			}
		case AuthNone:
			if !s.Viewers.empty() {
				problems = append(problems, fmt.Errorf("service %q: auth is none, so the viewers listed would be ignored", s.Name))
			}
		default:
			problems = append(problems, fmt.Errorf("service %q: auth is %q, but it is either \"required\" or \"none\"", s.Name, s.Auth))
		}
	}

	if len(problems) > 0 {
		return nil, errors.Join(problems...)
	}
	return &c, nil
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
