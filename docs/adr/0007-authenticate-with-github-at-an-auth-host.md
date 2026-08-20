# 0007. Authenticate against GitHub directly, at one auth host, with a signed cookie

- Date: 2026-08-20
- Status: Accepted

Supersedes [[0003]].

## Context

[[0003]] verified a token Cloudflare Access had already minted; the login itself
happened at the edge. [[0005]] removes Access, so the login flow has to exist
here. Three things have to be decided that Cloudflare was deciding on our
behalf.

**Where GitHub sends the user back.** A GitHub OAuth App has exactly one
authorization callback URL, and it cannot span subdomains. Every published
service is a different origin, so something has to collect the callback.

**What identity is checked against.** [[0004]]'s `viewers` block lists emails
and GitHub organisations, because those are the rules an Access policy can
express. Talking to the GitHub API directly means choosing what to ask for, and
the OAuth scopes follow from the choice.

**How the answer is carried.** Access issued a JWT per request, scoped to one
application by its AUD tag, and [[0003]] verified it on every request. Whatever
replaces it has to keep that per-service scoping, or a login for a service
anyone may see becomes a login for every service.

## Decision

### One auth host collects the login

`auth.<zone>` is reserved. It is not declarable as a service — the validator
rejects a service named `auth` — and it is always in the certificate allow-list
from [[0006]].

An unauthenticated request is redirected there with the original URL attached
and signed. The auth host runs the OAuth exchange against GitHub, checks the
resulting identity against the requested service's `viewers`, and redirects back
to the service host with a signed, single-use, short-lived token, which the
service host exchanges for its own cookie before sending the visitor to where
they were going.

The alternative was a GitHub App, which allows up to ten callback URLs. It was
rejected because publishing a service would once again mean visiting a settings
page outside this repository, and because ten is a ceiling. [[0004]] exists to
make publishing cheap; a step that cannot be automated from the box undoes it.
The auth host is the structure Cloudflare Access was already using, kept.

### GitHub login names, not email addresses

`viewers.emails` becomes `viewers.logins`, listing GitHub account names.
`viewers.github_orgs` is unchanged in meaning.

A login name comes from `/user` with no scope requested at all. An email address
requires `user:email`, and then requires getting the check right: the endpoint
returns every address on the account, verified and unverified, and treating an
unverified one as identity means anyone who types the right address into their
GitHub profile is admitted. Login names have no such failure mode — they are
unique, they are what the account *is*, and they do not change quietly.

Organisation membership is read from `/user/memberships/orgs/{org}` and requires
`state == "active"`. `/user/orgs` omits organisations whose membership the user
has set to private, which would deny people who are in fact members.
`read:org` is requested only when some service lists `github_orgs`.

### A signed, self-contained cookie, scoped to one service

The cookie carries the subject, the service name and an expiry, signed with
HMAC-SHA256. It is host-only — no `Domain` attribute, so it is never sent to a
sibling hostname — and `Secure`, `HttpOnly`, `SameSite=Lax`. There is no server
side state.

The service name inside the signature is what [[0003]] got from the per-service
AUD tag: a cookie issued for one service does not open another. The host-only
scoping is a second, independent barrier, and it is the one that matters for
`auth: none` services — a wildcard `Domain=.<zone>` cookie would have been
readable by anything published in the zone, including something deliberately
open to the public.

**The signing key is generated on first use.** If
`~/.config/devbox-proxy/session.key` does not exist, the process writes thirty-
two random bytes there with mode 600 and continues. A secret that can be
generated is generated; [[0002]] was stuck with a secret that could only be
obtained once from a third party, and that hazard does not have to be recreated
here.

**The GitHub client secret cannot be generated**, so it is placed by hand, once,
in `~/.config/devbox-proxy/github.yaml`, mode 600. Passing it in the environment
was considered and rejected: the process is long-lived, so the value would have
to survive a restart, which means it lives in `start-cuda`, in a host file, or
in the `docker run` arguments where `docker inspect` shows it. A file under
`$HOME` — the same place the signing key and the certificates already live —
keeps every secret in one directory, out of a public repository, and recoverable
by `docker restart` alone.

## Consequences

- **The correctness of the login is ours.** [[0003]] refused a four-star Traefik
  plugin because it was the component deciding whether a request is authorised.
  Code written here is held to the same standard and gets the property that was
  wanted: it can be read, and it can be tested — forged signatures, expired
  tokens, a cookie replayed against a different service, an unauthorised login,
  an organisation membership that is not active.
- **Sessions survive restarts and reloads**, because the key is on disk and the
  cookie needs no server-side lookup.
- **There is no way to revoke one session.** Rotating the signing key logs
  everybody out; that is the only lever. With a handful of users this is
  acceptable, and it is a deliberate trade against carrying a session store.
- **`auth.<zone>` is a single point of failure for logging in.** If it cannot
  get a certificate or the process is down, nobody can start a new session,
  though existing cookies keep working until they expire.
- **The login now depends on GitHub instead of Cloudflare.** [[0001]] noted that
  a Cloudflare outage made the services unreachable; a GitHub outage now blocks
  new logins, while existing sessions and `auth: none` services are unaffected.
  Nothing is unreachable merely because a third party is down.
- **`auth: none` still means wide open**, and more literally than in [[0003]]:
  there is no edge in front of it, and the hostname is enumerable via
  Certificate Transparency ([[0006]]). The setting exists for things that are
  fine to publish, and that has not changed.
- **Backends remain reachable on their own ports.** Unchanged from [[0003]];
  binding to `127.0.0.1` is still what prevents it, and the proxy still cannot
  enforce it.
- Migration rewrites `viewers.emails` to `viewers.logins` in both declaration
  files, and `devbox-publish` grows `--github-login` in place of `--email`.
