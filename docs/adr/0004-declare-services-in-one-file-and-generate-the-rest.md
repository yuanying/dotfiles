# 0004. Declare services in one file and generate the rest

- Date: 2026-08-20
- Status: Accepted

## Context

Publishing one service touches three unrelated systems: a Traefik router in the
container, an `AAAA` record in Cloudflare DNS, and an Access application with a
policy in Cloudflare Zero Trust. Done by hand that is three consoles and a
guaranteed drift — a router with no DNS record, an Access application whose AUD
the proxy does not know about, a DNS record for a service that was deleted
months ago.

A publishing mechanism that is annoying to use does not get used; the servers go
back to being raw HTTP on a high port, which is the situation [[0001]] exists to
fix.

## Decision

**One declaration file, `devbox/proxy/services.yaml`, is the source of truth.
Everything else is generated from it.**

```yaml
zone: oeilvert.org
team_domain: yuanying.cloudflareaccess.com
origin: 2405:6581:8580:310::153

defaults:
  auth: required

services:
  - name: llama          # -> llama.oeilvert.org
    port: 8081           # -> http://127.0.0.1:8081
    auth: required
    aud: <application audience tag>
    viewers:
      emails: [someone@example.com]
      github_orgs: [some-org]
```

Two scripts consume it:

- `generate-traefik-config.sh` writes Traefik's static and dynamic
  configuration. It is a pure function of the declaration file — same input,
  same bytes out — which is what makes it testable.
- `sync-cloudflare.sh` reconciles Cloudflare: `AAAA` records and Access
  applications and their policies. It writes the AUD tag Cloudflare returns back
  into the declaration file, so that the next `generate` picks it up.

Adding a service is: edit the file, run `sync-cloudflare.sh` with a token in the
environment, run `devbox-proxy reload`.

### The declaration file is committed, and holds no secrets

Hostnames, ports, GitHub organisations and the AUD tag are identifiers, not
credentials. The AUD tag names an Access application; it grants nothing — a
token bearing it still has to carry a valid Cloudflare signature ([[0003]]). The
two things that *are* secret are handled elsewhere: the origin private key lives
under `$HOME` ([[0002]]) and the Cloudflare API token is passed in the
environment for one script run and never written down.

Keeping the AUD in the committed file rather than in generated runtime state is
deliberate: it keeps `generate-traefik-config.sh` a pure function, so the golden
tests do not need Cloudflare.

### Authorisation is expressed here but enforced at the edge

`viewers` becomes an Access policy. The origin never consults it — it only
checks that Cloudflare vouched for the request against *this* application
([[0003]]). Cloudflare's GitHub identity provider is registered with the
`Organizations and teams (read-only)` and `Email addresses (read-only)` scopes,
so a policy can name either. `auth: none` skips the application entirely.

### Bash, and a golden test

The scripts are bash with `jq`, `yq` and `curl`, matching `devbox/scripts/` and
the rest of the repository, and adding two pinned binaries rather than a
runtime. Versions go in `devbox/Dockerfile` as `ARG <NAME>_VERSION` with a
`# renovate:` annotation, like everything else there.

Tests are `bats`, and they cover the transformation: declaration file in,
expected Traefik configuration out, plus the input validation. They stop at the
edge of the network. Whether Cloudflare's API accepted a policy, and whether a
browser actually completes a GitHub login, is verified by hand — mocking those
would test the mock.

## Consequences

- Cloudflare state that nobody declared here still gets removed by the sync
  script if it is inside the namespace it manages. It touches only records and
  applications whose hostname is `<name>.<zone>` for a name it knows, and it
  never touches the apex or anything else in the zone.
- Editing Traefik's configuration by hand is pointless — it is overwritten on
  the next `generate`. The generated files carry a "do not edit" header saying
  so.
- The AUD tag is written into the file by a script, so the file is both
  hand-edited and machine-edited. `yq` preserves comments on in-place edits,
  but the diff after a `sync` is expected and should be committed.
- A hostname with a dot in it is a validation error, not a silent misconfigure —
  the reason is in [[0002]].
- Removing a service means removing it from the file and running both scripts.
  Deleting the Access application without deleting the router would leave the
  route unauthenticated at the edge; the origin still refuses it, because the
  AUD no longer verifies. The failure direction is closed.
