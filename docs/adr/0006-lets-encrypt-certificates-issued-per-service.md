# 0006. Let's Encrypt certificates, one per service, renewed in the background

- Date: 2026-08-20
- Status: Accepted

Supersedes [[0002]].

## Context

[[0002]] chose a wildcard Origin CA certificate because the only party that ever
saw it was Cloudflare. [[0005]] removes Cloudflare from the request path, so the
certificate is now presented to browsers and has to be publicly trusted.
Let's Encrypt is the answer to that; the question is which shape.

Let's Encrypt has issued wildcards since ACMEv2 in March 2018, but **a wildcard
can only be validated over DNS-01.** A certificate for `*.<zone>` means writing
a TXT record under the zone every renewal, every ninety days, forever. That
requires a credential with DNS edit authority on the zone to be **resident** on
the box — which is precisely the arrangement [[0002]] refused:

> the credential that issues certificates is strictly more dangerous than the
> certificate it issues

Per-service certificates need no such thing. HTTP-01 validates by serving a
token on port 80, and grey cloud ([[0005]]) means Let's Encrypt reaches the
devbox directly over IPv6 rather than being intercepted by the edge. The
wildcard `AAAA` record still exists — a wildcard DNS record and a wildcard
certificate are independent choices, and only the second one costs a token.

What per-service issuance costs instead is names in public. Every certificate is
logged to Certificate Transparency, so `sd-webui.poissonnerie.dev` becomes
enumerable at `crt.sh` by anyone. A wildcard would have kept the labels private.

## Decision

**One Let's Encrypt certificate per published hostname, over HTTP-01, managed by
certmagic. No API credential of any kind is stored on the box.**

- **Port 80** answers ACME challenges and redirects everything else to HTTPS.
  It has to be open for HTTP-01 regardless.
- **The declaration file is the allow-list.** certmagic's on-demand decision
  function accepts a hostname only if `services.<hostname>.yaml` declares it (or
  it is the auth host, [[0007]]). A wildcard DNS record means any label reaches
  the box; without this, a stranger's request for `xyz.<zone>` would make us ask
  Let's Encrypt for a certificate we do not want, repeatedly.
- **Every declared hostname is also registered for management at startup**,
  asynchronously. Registration does not block startup and does not need the
  network to succeed; certmagic retries in the background. Registered
  certificates are watched by the maintenance loop and renewed when the
  remaining lifetime falls below certmagic's threshold — a third of the validity
  period, so around thirty days for a ninety-day certificate.
- **`devbox-proxy status` prints, per hostname, the expiry, the time of the last
  renewal attempt, and why it failed if it did.** If a certificate is close to
  expiry and not renewing, `entrypoint.sh` prints a warning at container start.
- **The ACME directory is overridable by environment variable**, defaulting to
  production. Verifying a change goes through the staging directory, which does
  not consume the production rate limit.

### Why on-demand and managed, rather than one or the other

On-demand alone: a certificate that is not in the in-memory cache is not watched
by the maintenance loop. A service nobody visits for ninety days would silently
expire and be re-issued on the next visit. It works, but it is not "renewed
before it expires", and the first person to notice would be a browser showing a
warning.

Managed alone, synchronously at startup: the process would need the network to
start. [[0001]] established that the devbox comes up whether or not any of this
works, and a box that will not serve anything because it rebooted while the
uplink was down is worse than the problem being solved.

Registering asynchronously gives the renewal loop its list without making
startup depend on it, and keeping the on-demand path covers hostnames added by
a reload ([[0008]]) between restarts.

### Why not keep a long-lived certificate

The appeal of [[0002]]'s fifteen-year Origin CA certificate was that nothing
ever had to happen again. Its stated cost was that nothing warns about expiry
and the key cannot be recovered. Ninety-day certificates invert both: renewal is
routine and automatic, the key is regenerated as a matter of course, and losing
the directory means the next request re-issues. In exchange, a renewal that
keeps failing is a real outage on a timer — which is what the status output and
the startup warning are for.

## Consequences

- **Certificates renew themselves.** [[0002]]'s "nothing warns about expiry" is
  resolved; nothing needs to warn, because nothing needs to be done.
- **A sustained renewal failure is an outage with a countdown.** Roughly thirty
  days of retries pass before anything breaks, and the failure is visible in
  `status` and at container start throughout — but nobody is paged.
- **Port 80 must be open** on the devbox's IPv6. It serves only ACME challenges
  and redirects.
- **Published hostnames are public.** Certificate Transparency makes every
  `<name>.<zone>` enumerable. Combined with [[0005]] putting the IPv6 in DNS,
  the existence and address of every service is discoverable by anyone; what
  protects them is [[0007]], on every path, not obscurity.
- **Let's Encrypt is now in the critical path for a new service.** The first
  request to a newly declared hostname waits a few seconds for issuance, and
  fails if Let's Encrypt is unreachable or rate-limiting. The duplicate
  certificate limit — five per identical name set per week — is reachable while
  iterating, which is why staging is a flag away.
- **Certificate names stay one label deep**, unchanged from [[0002]] but for a
  different reason: HTTP-01 has no such restriction, but the wildcard `AAAA`
  record does not cover `a.b.<zone>`. Namespace in the service name.
- **The zone's SSL mode stops mattering.** Nothing goes through the edge.
- A dependency on certmagic enters the trust boundary. Unlike the Traefik plugin
  [[0003]] rejected, it is the certificate stack Caddy ships, released under
  tags that can be pinned the way everything else in `devbox/` is.

## Notes from implementing it

Two things turned out differently from the description above. Neither changes
the decision, and both are worth writing down because the code does not read
the way this record led you to expect.

**The challenge is usually TLS-ALPN-01, not HTTP-01.** certmagic tries TLS-ALPN
first and falls back to HTTP-01. Both validate over a port the devbox already
answers on and neither needs a DNS credential, which is the property this record
actually chose them for — so nothing above is wrong except the name. Port 80
stays open regardless: it redirects to HTTPS, and it is the fallback when
TLS-ALPN cannot be used.

**Registering names for renewal takes more than `ManageAsync`.** With an
`OnDemandConfig` set, certmagic's `manageAll` files each name in an on-demand
allow-list and returns without obtaining or caching anything:

    // if on-demand is configured, defer obtain and renew operations
    if cfg.OnDemand != nil {
        cfg.OnDemand.hostAllowlist[domainName] = struct{}{}
        continue
    }

The maintenance loop only ever looks at certificates in the cache, so the two
mechanisms this record wanted to run together do not, as written: registration
becomes a no-op and only visited names get renewed. `CertManager.Manage` does
the caching itself — load from storage, obtain if there is none — which is what
`manageOne` does internally when on-demand is not in the way. Both are exported,
so this needs no fork and no patch, only the knowledge that the obvious call
does not do the obvious thing.
