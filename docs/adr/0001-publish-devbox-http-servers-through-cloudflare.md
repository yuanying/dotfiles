# 0001. Publish devbox HTTP servers through Cloudflare

- Date: 2026-08-20
- Status: Accepted

## Context

The devbox containers (`anietta` on simone, ROCm; `boucherie` on poissonnerie,
CUDA) are used to run HTTP servers — `llama-server` and friends. Each container
holds a global IPv6 address of its own (`start-rocm` / `start-cuda` pass
`--network v6net --ip6 …`), so those servers are already reachable from the
public Internet as plain HTTP on a high port, with no TLS and no authentication
in front of them. `anietta.oeilvert.org` resolves to that address today.

What is wanted is `https://<service>.<zone>` per service, behind a GitHub login,
with adding a service being cheap enough that it happens. Each devbox gets a
zone of its own: `oeilvert.dev` for anietta, `poissonnerie.dev` for boucherie.

Constraints that shaped the answer:

- `oeilvert.dev` and `poissonnerie.dev` are already on Cloudflare nameservers,
  and both are empty — neither holds an `A`, `AAAA`, `CNAME` or `MX` record.
  Nothing else is published from either, which is why they were picked.
- `anietta.oeilvert.org` — the name SSH and mosh reach the devbox on — lives in
  a different zone, and nothing here ever touches it.
- Cloudflare Zero Trust is free up to 50 users, and that tier includes Access
  and the GitHub identity provider. Nothing here needs a paid plan.
- The devbox container's `$HOME` is a bind mount of the host's, so anything
  written there survives the container being rebuilt; anything written
  elsewhere does not.
- `yuanying/dotfiles` is a public repository.

## Decision

Terminate the public hostname at Cloudflare and let Cloudflare reach the devbox
directly over IPv6.

- **DNS**: an `AAAA` record per service pointing at the devbox's global IPv6,
  with the Cloudflare proxy on (orange cloud). The devbox is the origin; there
  is no bastion, tunnel or relay in between.
- **Authentication at the edge**: Cloudflare Access, with GitHub as the identity
  provider. The proxy inside the devbox implements no login flow of its own.
- **Reverse proxy inside the container**: the proxy runs in the devbox itself,
  because that is where the backends are — it reaches them over `127.0.0.1`,
  and the address Cloudflare connects to is the devbox's own IPv6.
- **Traefik**, configured through its file provider with statically generated
  routers. Nothing is auto-discovered.
- **Everything lives in `devbox/`** in this repository, next to the `Dockerfile`
  and `entrypoint.sh` that it has to cooperate with.

Cloudflare Tunnel was not chosen. It would work, but the devbox already has a
routable address that Cloudflare can reach, so a tunnel would add a daemon and
an outbound dependency to solve a problem that does not exist here.

Traefik was chosen over nginx or Caddy for one forward-looking reason: devbox
runs a Docker socket mount, and when services start being containers rather
than processes, Traefik's Docker provider replaces the generated file with
labels on those containers. The file provider is the same product configured a
different way, so that move costs nothing today.

## Consequences

- The devbox's global IPv6 is the origin address and is therefore discoverable.
  Anyone who learns it can connect to port 443 directly, bypassing Cloudflare
  and its Access check. That hole is closed in [[0003]], not here.
- Requests are terminated twice, so the devbox needs a certificate the
  Cloudflare edge will accept — see [[0002]].
- Cloudflare Access is a hard dependency of the login flow. If Cloudflare is
  down, the services are unreachable; they are development conveniences, and
  SSH into the box is unaffected, so this is acceptable.
- Backends keep binding to `127.0.0.1` or to all interfaces on a high port. The
  proxy does not require them to change, which means an unproxied service also
  stays reachable on its raw port — see [[0003]] for why that is tolerated.
