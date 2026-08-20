# 0002. Use a wildcard Origin CA certificate and Full (strict)

- Date: 2026-08-20
- Status: Accepted

## Context

[[0001]] puts Cloudflare in front of the devbox and has it connect to the
container's own IPv6 on port 443. That leg needs TLS, and Cloudflare's SSL mode
decides how hard it looks at the certificate the origin presents:

| Mode | Origin certificate is | Consequence |
|---|---|---|
| Flexible | not used at all | the origin leg is plaintext |
| Full | not verified | any certificate is accepted, valid or forged |
| Full (strict) | verified | the origin must present something Cloudflare trusts |

Relevant facts about the free tier:

- Cloudflare Origin CA certificates are free on every plan and are trusted by
  Cloudflare — and only by Cloudflare — for connections to an origin.
- The private key is shown once, at issuance. Cloudflare does not store it.
  There is no "download it again": recovery means issuing a new certificate.
- Origin CA certificates do not send expiry notifications.
- Universal SSL, the free edge certificate, covers the apex and one level of
  subdomain. `a.b.example.com` needs Advanced Certificate Manager, which is paid.

## Decision

**One wildcard Origin CA certificate per zone — `*.oeilvert.dev` for anietta,
`*.poissonnerie.dev` for boucherie, each plus its apex — with the zone's SSL
mode set to Full (strict).**

Service hostnames are therefore restricted to a single label —
`llama.oeilvert.dev`, never `llama.devbox.oeilvert.dev`. The generator rejects a
service name containing a dot. This is a free-tier constraint on the *edge*
certificate, and it happens to line up with the wildcard on the *origin*
certificate, which covers one level for the same reason.

One certificate covers every service **in one zone**, so adding a service never
touches TLS. A certificate is scoped to the zone it was issued for, so each
devbox issues and holds its own: `issue-origin-cert.sh` reads the zone from that
host's declaration file, and the pair it writes into
`~/.config/devbox-proxy/certs` is that zone's. Two devboxes in one zone would
have shared a certificate; a zone each means two, and neither can stand in for
the other. That is the cost of the split, and it buys the isolation below.

Splitting the zones has a second effect worth stating: service names no longer
collide. `llama` on anietta is `llama.oeilvert.dev` and `llama` on boucherie is
`llama.poissonnerie.dev`, so the two devboxes never have to negotiate over a
name, and neither `sync-cloudflare.sh --prune` can reach the other's records.

**The private key lives in `~/.config/devbox-proxy/certs/`, mode 600, and is
never committed.** The container's `$HOME` is the host's, so the key survives
rebuilding the image; the repository is public, so it cannot live here.

**Issuance is a script that can be re-run at any time**
(`devbox/proxy/bin/issue-origin-cert.sh`). It generates a fresh key and CSR,
calls the Cloudflare API, and writes the pair. Because Cloudflare does not keep
the key, re-issuing *is* the recovery procedure, and it is also the renewal
procedure — there is no notification to wait for.

### Why not self-signed with Full

Full skips verification entirely: it accepts whatever certificate the origin
presents, including one an attacker presents. Against an on-path attacker
between Cloudflare and the origin it is worth about as much as Flexible. Origin
CA costs nothing and is not meaningfully more work than generating a self-signed
certificate — it is the same `openssl req`, followed by one API call instead of
`openssl x509`. Paying nothing to downgrade the security of the origin leg is a
bad trade, so Full (strict) it is.

### Why not issue a certificate on every devbox start

It would remove the "the key is only shown once" hazard by making the key
disposable, and it would remove expiry from the picture. It was rejected because
of what it requires to be sitting on the box:

- Issuing needs a Cloudflare credential with certificate-issuing authority. To
  make it automatic, that credential has to be **resident** — a file or an
  environment variable that is present at every boot, readable by anything
  running as the user.
- The credential that issues certificates is strictly more dangerous than the
  certificate it issues. A leaked origin key lets someone impersonate this
  origin to Cloudflare, which already requires being on the network path. A
  leaked issuing credential lets someone mint origin certificates for the whole
  zone, from anywhere.

So the trade is: keep one long-lived secret with narrow blast radius (the origin
key), instead of one long-lived secret with a wide one (the API token). The API
token is passed in the environment for the duration of a manual script run and
is not stored anywhere.

The same reasoning applies to [[0004]]'s Cloudflare sync script.

## Consequences

- **Nothing warns about expiry.** Certificates are requested with a long
  validity, and re-issuing is one command, but the calendar is the operator's
  problem. `devbox-proxy status` prints the certificate's `notAfter` so that the
  answer is at least one command away.
- Losing `~/.config/devbox-proxy/certs/origin.key` means re-issuing. That is a
  designed-for path, not an incident.
- Service hostnames are stuck at one level. Namespacing by host
  (`llama.gpu.oeilvert.dev`) is not available without paying for ACM; namespace
  in the service name instead (`gpu-llama.oeilvert.dev`).
- Full (strict) is a **zone-wide** setting, but both zones were empty when they
  were picked — no `A`, `AAAA`, `CNAME` or `MX` record in either — so there is
  no other origin to break, and the mode can be switched without a survey. That
  stops being true the moment something else is published from one of them: any
  origin added later has to present a certificate Cloudflare trusts, or it fails
  the day it is added.
- Two zones mean two certificates, two expiry dates and two things to re-issue
  after a loss. `devbox-proxy status` prints the date of the one on the box it
  runs on, which is the one that host cares about; there is no single place that
  shows both.
