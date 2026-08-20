# 0005. Replace the Cloudflare-dependent proxy with a single Go binary

- Date: 2026-08-20
- Status: Accepted

Supersedes [[0001]].

## Context

[[0001]] put Cloudflare in front of the devbox and Traefik inside it. What that
shape actually costs, now that it has been built and used:

- **Five moving parts.** A Traefik process, a Python ForwardAuth verifier, a
  configuration generator, a certificate issuer, and a Cloudflare reconciler.
  [[0004]] hid them behind one declaration file, but they are all still there to
  be understood, tested and repaired.
- **Two Cloudflare API tokens**, with different scopes, remembered and pasted
  into an environment for every service added and every certificate re-issued.
- **An identifier that has to make a round trip.** Cloudflare mints the AUD tag
  when the Access application is created; the origin needs it to verify
  anything; so it is written back into the declaration file and committed. A
  stale one turns every request into a 403, which [[0003]] lists as the most
  likely failure.
- **Access is a hard dependency of the login flow**, as [[0001]] acknowledged.
  Cloudflare being down means the services are unreachable.

Set against that, what is genuinely needed is three things: terminate TLS,
check that the visitor is someone we allow, and forward to `127.0.0.1`.

Two facts changed the arithmetic since [[0001]] was written:

- Both zones are still empty apart from these services, so nothing else depends
  on how they are configured at the edge.
- The devbox's global IPv6 makes it a first-class origin, reachable by
  Let's Encrypt for an HTTP-01 challenge just as it is reachable by Cloudflare.
  The address that made a tunnel unnecessary in [[0001]] also makes the edge
  unnecessary for issuing certificates.

## Decision

**Reduce Cloudflare to authoritative DNS, and put TLS, authentication and
proxying in one Go binary.**

- **DNS**: one wildcard `AAAA` record, `*.<zone>` pointing at the devbox's
  global IPv6, **grey cloud** — DNS only, not proxied. Placed by hand once. No
  record is ever created or deleted by anything running on the box.
- **Certificates**: Let's Encrypt, per service, over HTTP-01 — see [[0006]].
- **Authentication**: GitHub OAuth implemented in the binary, with the login
  flow collected at a single auth host — see [[0007]].
- **Proxying**: `httputil.ReverseProxy` to `127.0.0.1:<port>`, routed from the
  same declaration file [[0004]] already defines.

`services.<hostname>.yaml` survives; the machinery underneath it does not.
`generate-traefik-config.sh`, `issue-origin-cert.sh`, `sync-cloudflare.sh` and
`cf-access-forwardauth` are deleted, along with the Access applications, the
Origin CA certificate, the AUD tags and both API tokens.

### Why Traefik goes

[[0001]] chose Traefik over nginx or Caddy for one forward-looking reason: when
services became containers rather than processes, the Docker provider would
replace the generated file with labels. That future has not arrived, and in the
meantime Traefik's presence imposes three costs — a configuration generator to
test, an HTTP round trip per request because the open-source proxy has no
middleware that understands a JWT ([[0003]]), and a pinned version to track.

Once certificates and authentication live in the same process anyway, keeping a
second process for routing alone is hard to justify. If Docker-label discovery
is wanted later, it is a few hundred lines against the Docker API — a real cost,
but a smaller one than the three being paid every day now.

### Why grey cloud rather than keeping the orange one

Leaving the proxy on was viable: Cloudflare trusts publicly-issued certificates,
so Full (strict) would keep working with a Let's Encrypt certificate at the
origin, and the edge would still absorb DDoS traffic and hide the IPv6 address.
It was rejected because:

- The edge intercepts port 80, so HTTP-01 becomes unavailable and the only
  route to a certificate is DNS-01 — which means a resident Cloudflare API
  token, the exact arrangement [[0002]] argued against. See [[0006]].
- With authentication moved into the origin ([[0007]]), it holds on every path.
  The back door [[0003]] exists to close — a request arriving straight at the
  IPv6 address — is shut by the same check that guards the front door, rather
  than by a second mechanism. The edge stops being load-bearing for security.
- Reducing the dependency to DNS is the point. A dependency that is only
  consulted by resolvers is one that cannot break a deployment, leak a token, or
  need reconciling.

What this costs is real: the devbox's IPv6 goes into public DNS rather than
merely being discoverable, and there is no DDoS absorption in front of it.

### How the binary gets built

A shell script runs from the checkout it lives in; a compiled binary does not.
The current proxy is repaired by `git pull`, and in a worktree it is whatever
that worktree contains — a property the repository relies on elsewhere and one
worth not losing.

Building in the `Dockerfile`, the way the Traefik binary is installed today, was
rejected for that reason: changing one line of the proxy would mean rebuilding
the image and recreating the container, which is a heavy enough loop that it
discourages small fixes.

**`devbox-proxy` stays a thin shell wrapper. `start` compares the sources
against the built binary and runs `go build` when the sources are newer or the
binary is missing**, writing to `~/.config/devbox-proxy/bin/`, keyed by the
checkout it was built from so that a worktree gets its own. Go is already in the
image — the `golang_builder` stage and `/usr/local/go` are there for editing Go
code — so this adds no dependency, and removing Traefik removes one.

### Testing

The behaviour worth testing is inside the binary — token forgery, expiry, a
cookie presented to the wrong service, the OAuth exchange, which hostnames the
on-demand decision function will and will not accept. None of that is reachable
from a shell. Tests move to `go test`.

`bats` stays where a shell test is still the right shape: the `devbox-publish`
CLI in `skills/`, and the wrapper's own behaviour -- building when the sources
are newer, starting, stopping, and refusing a reload that does not validate --
which is about processes and files rather than about code paths. `bats -r .`
from the repository root continues to run both.

### Migration

One cut, not a parallel run: two services, one user, and port 443 cannot be
shared by two processes anyway, so a parallel run would exercise a path that is
not the real one. Verify locally against the Let's Encrypt staging directory,
add the wildcard record, delete the per-service ones, stop Traefik, start the
new binary, confirm a login in a browser, then remove the Access applications
and revoke the Origin CA certificate.

## Consequences

- **One process, one configuration file.** Adding a service is editing YAML and
  reloading; nothing outside the box is touched, and no token is needed.
- **No Cloudflare API token exists anywhere** — not on disk, not in an
  environment, not in a password manager for occasional use. [[0002]] traded a
  narrow long-lived secret for a wide one that was never stored; this removes
  the choice.
- **A Cloudflare outage no longer takes the services down**, as long as DNS
  resolves. The login dependency moves to GitHub — see [[0007]].
- **Being right about authentication is now our problem.** [[0003]] rejected a
  Traefik plugin on supply-chain grounds because it was the component deciding
  whether a request is authorised; that same standard now applies to code in
  this repository. It is readable and tested, which is the property that was
  being asked for in the first place.
- **The IPv6 address is published in DNS and has nothing in front of it.**
  [[0001]] already treated the address as discoverable; this makes it public.
  Every service is exposed to whatever arrives, with the binary as the only
  thing between the Internet and `127.0.0.1`.
- **The path to Traefik's Docker provider is closed.** Reopening it means
  writing label discovery.
- Most of the existing `bats` suite disappears with the scripts it covers. The
  transformations it was pinning still need pinning, in Go.
- **The Go toolchain becomes a runtime dependency of starting the proxy**, not
  just of developing it, and the first start after a change waits for a build.
  In exchange, fixing the proxy is still `git pull`.
- The devbox still starts without any of this, and more reliably than before —
  see [[0006]] and [[0008]].
