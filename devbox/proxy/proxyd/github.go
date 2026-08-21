package main

// Talking to GitHub: the OAuth exchange, and the two questions that decide
// whether somebody is admitted.
//
// docs/adr/0007 checks GitHub account names rather than email addresses. A
// login comes back from /user with no scope requested at all, and it is what
// the account *is* -- an address can be unverified, one of several, or changed
// quietly, and treating an unverified one as identity admits whoever typed it
// into their profile. Organisation membership is read from the memberships
// endpoint because /user/orgs omits memberships the member has made private,
// which would deny people who are in fact members.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/goccy/go-yaml"
)

// GitHub is a client for one OAuth application.
type GitHub struct {
	ClientID     string
	ClientSecret string

	// Endpoints, overridable so the tests can stand in for GitHub.
	authorizeURL string
	tokenURL     string
	apiBase      string

	client *http.Client
}

// NewGitHub returns a client for the given OAuth application.
func NewGitHub(clientID, clientSecret string) *GitHub {
	return &GitHub{
		ClientID:     clientID,
		ClientSecret: clientSecret,
		authorizeURL: "https://github.com/login/oauth/authorize",
		tokenURL:     "https://github.com/login/oauth/access_token",
		apiBase:      "https://api.github.com",
		client:       &http.Client{Timeout: 15 * time.Second},
	}
}

// AuthorizeURL is where the visitor's browser is sent to log in. The client
// secret is not part of it: this URL is handed to the browser.
func (g *GitHub) AuthorizeURL(redirectURI, state, scope string) string {
	q := url.Values{
		"client_id":    {g.ClientID},
		"redirect_uri": {redirectURI},
		"state":        {state},
	}
	if scope != "" {
		q.Set("scope", scope)
	}
	return g.authorizeURL + "?" + q.Encode()
}

// Exchange trades the code GitHub sent back for an access token.
func (g *GitHub) Exchange(ctx context.Context, code, redirectURI string) (string, error) {
	form := url.Values{
		"client_id":     {g.ClientID},
		"client_secret": {g.ClientSecret},
		"code":          {code},
		"redirect_uri":  {redirectURI},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	// Without this GitHub answers in form encoding.
	req.Header.Set("Accept", "application/json")

	resp, err := g.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("github: token exchange returned %s", resp.Status)
	}

	var out struct {
		AccessToken      string `json:"access_token"`
		Error            string `json:"error"`
		ErrorDescription string `json:"error_description"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", fmt.Errorf("github: token exchange returned something that is not JSON: %w", err)
	}
	// A rejected code comes back as 200 with an error in the body, so the
	// status alone is not the answer.
	if out.Error != "" {
		return "", fmt.Errorf("github: %s (%s)", out.Error, out.ErrorDescription)
	}
	if out.AccessToken == "" {
		return "", errors.New("github: token exchange returned no token")
	}
	return out.AccessToken, nil
}

// Login is the account name the token belongs to.
func (g *GitHub) Login(ctx context.Context, token string) (string, error) {
	var out struct {
		Login string `json:"login"`
	}
	status, err := g.get(ctx, token, "/user", &out)
	if err != nil {
		return "", err
	}
	if status != http.StatusOK {
		return "", fmt.Errorf("github: /user returned %d", status)
	}
	if out.Login == "" {
		return "", errors.New("github: /user returned no login")
	}
	return out.Login, nil
}

// InOrg reports active membership. A membership that exists but is still
// pending is an invitation nobody has accepted, which is not membership.
func (g *GitHub) InOrg(ctx context.Context, token, org string) (bool, error) {
	var out struct {
		State string `json:"state"`
	}
	status, err := g.get(ctx, token, "/user/memberships/orgs/"+url.PathEscape(org), &out)
	if err != nil {
		return false, err
	}
	switch status {
	case http.StatusOK:
		return out.State == "active", nil
	case http.StatusNotFound:
		// Not a member. An ordinary answer, not a failure.
		return false, nil
	default:
		return false, fmt.Errorf("github: membership of %q returned %d", org, status)
	}
}

// Admits decides whether this identity may see a service.
//
// A listed login is settled without asking GitHub anything. Organisations cost
// a request each, so they are only consulted when the login did not match.
// Anything that goes wrong is an error and a refusal, never an admission --
// the direction 0003 established for this component.
func (g *GitHub) Admits(ctx context.Context, token, login string, v Viewers) (bool, error) {
	for _, allowed := range v.Logins {
		if strings.EqualFold(allowed, login) {
			return true, nil
		}
	}

	var problems []error
	for _, org := range v.GitHubOrgs {
		member, err := g.InOrg(ctx, token, org)
		if err != nil {
			// Keep going: another organisation may still admit them, and a
			// single outage should not be reported as a clean refusal.
			problems = append(problems, err)
			continue
		}
		if member {
			return true, nil
		}
	}
	if len(problems) > 0 {
		return false, errors.Join(problems...)
	}
	return false, nil
}

func (g *GitHub) get(ctx context.Context, token, path string, out any) (int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, g.apiBase+path, nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")

	resp, err := g.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return resp.StatusCode, err
	}
	if resp.StatusCode == http.StatusOK {
		if err := json.Unmarshal(body, out); err != nil {
			return resp.StatusCode, fmt.Errorf("github: %s returned something that is not JSON: %w", path, err)
		}
	}
	return resp.StatusCode, nil
}

// Credentials is the GitHub OAuth application, read from github.yaml.
type Credentials struct {
	ClientID     string `yaml:"client_id"`
	ClientSecret string `yaml:"client_secret"`
}

// LoadGitHubCredentials reads the one secret that cannot be generated.
// docs/adr/0007: GitHub issues it, so it is placed by hand, once, mode 600.
func LoadGitHubCredentials(path string) (*Credentials, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if info.Mode().Perm()&0o077 != 0 {
		return nil, fmt.Errorf("%s is readable by other accounts (mode %o); chmod 600 it", path, info.Mode().Perm())
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Credentials
	if err := yaml.UnmarshalWithOptions(data, &c, yaml.Strict()); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if c.ClientID == "" || c.ClientSecret == "" {
		return nil, fmt.Errorf("%s needs both client_id and client_secret", path)
	}
	return &c, nil
}
