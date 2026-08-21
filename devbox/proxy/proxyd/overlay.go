package main

// The half of the configuration that does not live in the repository.
//
// docs/adr/0009: `yuanying/dotfiles` is public, so everything in the
// declaration file is published -- including the GitHub account names of
// whoever is allowed in, and including the existence of services that are
// nobody else's business. This file lets a second declaration sit in the state
// directory and be merged over the first.
//
// Merged, not chosen between: what is fine to publish stays in the repository
// where it is reviewed and versioned, and what is not goes beside it. Moving an
// entry from one to the other changes nothing about what gets served.

import (
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/goccy/go-yaml"
)

// Overlay is a declaration fragment. It is the same shape as the declaration
// file minus the zone, which is the declaration's alone to name: an overlay
// that could change it would move every hostname and every certificate at once.
type Overlay struct {
	Services []Service `yaml:"services"`
}

// LoadOverlay reads the overlay. Not having one is the ordinary case and is not
// an error.
//
// Unlike the signing key and the GitHub credentials, no file mode is enforced.
// Nothing in here is a secret -- account names and port numbers are ordinary
// identifiers. They are outside the repository because the repository is
// published, which is a question of privacy rather than of secrecy.
func LoadOverlay(path string) (*Overlay, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	o, err := ParseOverlay(data)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return o, nil
}

// ParseOverlay validates an overlay's syntax. What it means only becomes
// checkable once it has been merged, so the rules live in Config.validate.
func ParseOverlay(data []byte) (*Overlay, error) {
	var o Overlay
	if err := yaml.UnmarshalWithOptions(data, &o, yaml.Strict()); err != nil {
		return nil, err
	}
	return &o, nil
}

// Apply folds an overlay into the declaration and revalidates the result.
//
// An entry naming a service the declaration already has updates it: a port or
// an auth mode that is set wins, and viewers are added to whoever is already
// listed rather than replacing them. An entry naming anything else is a new
// service, published exactly as if the declaration had said so.
func (c *Config) Apply(o *Overlay) error {
	if o == nil {
		return nil
	}

	for _, entry := range o.Services {
		i := c.indexOf(entry.Name)
		if i < 0 || entry.Name == "" {
			c.Services = append(c.Services, entry)
			continue
		}

		if entry.Port != 0 {
			c.Services[i].Port = entry.Port
		}
		if entry.Auth != "" {
			c.Services[i].Auth = entry.Auth
		}
		// Viewers are never replaced. Someone the declaration lists does not
		// lose access because the overlay mentioned the service.
		c.Services[i].Viewers.Logins = mergeNames(c.Services[i].Viewers.Logins, entry.Viewers.Logins)
		c.Services[i].Viewers.GitHubOrgs = mergeNames(c.Services[i].Viewers.GitHubOrgs, entry.Viewers.GitHubOrgs)
	}

	c.applyDefaults()
	return c.validate()
}

func (c *Config) indexOf(name string) int {
	for i := range c.Services {
		if c.Services[i].Name == name {
			return i
		}
	}
	return -1
}

// Unreachable is every service that asks for a login and admits nobody.
//
// This used to be a parse error. It is a warning now because the guest list can
// arrive from two places, so it cannot be judged from either alone -- and
// requiring an overlay to exist would defeat its purpose. `check`, `status` and
// container startup all report it, because a login that can never succeed is a
// poor way to discover an empty list.
func (c *Config) Unreachable() []string {
	var out []string
	for _, s := range c.Services {
		if s.Auth == AuthRequired && s.Viewers.empty() {
			out = append(out, s.Name)
		}
	}
	sort.Strings(out)
	return out
}

// mergeNames concatenates without repeating. GitHub account and organisation
// names are case-insensitive, so two spellings are one name.
func mergeNames(existing, extra []string) []string {
	seen := make(map[string]bool, len(existing)+len(extra))
	out := make([]string, 0, len(existing)+len(extra))
	for _, list := range [][]string{existing, extra} {
		for _, name := range list {
			key := strings.ToLower(name)
			if name == "" || seen[key] {
				continue
			}
			seen[key] = true
			out = append(out, name)
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
