# 0008. Keep the process lifecycle, and reload without dropping connections

- Date: 2026-08-20
- Status: Accepted

## Context

`devbox-proxy` has `start`, `stop`, `restart`, `reload` and `status`, and
`entrypoint.sh` calls `start`. That interface is worth keeping — it is what the
`devbox-publish` skill drives, and it is what a person types. Collapsing five
processes into one ([[0005]]) changes what happens underneath it, in two places.

**Starting used to depend on a certificate.** With the Origin CA certificate
absent, `start` announced that it had found nothing and started nothing, which
meant a devbox that had never run `issue-origin-cert.sh` published nothing at
all. [[0006]] removes the precondition: certificates are obtained on demand and
in the background.

**Reloading used to be able to take everything down.** An authenticated service
has no AUD tag until `sync-cloudflare.sh` has run, and Traefik cannot be
configured without one, so `reload` would stop Traefik and then fail to start
it — taking down every service that was working in order to add one that was
not. A guard was added: do not reload if the configuration does not generate.
[[0005]] deletes AUD tags, so that specific trap is gone, but the shape of the
mistake — losing a working configuration while applying a broken one — is not
specific to Traefik.

A single process also makes a third option available that was not available
before: applying new configuration without the process going away.

## Decision

**The commands keep their names and their meanings. `entrypoint.sh` still calls
`start`, and the pid file stays in `~/.config/devbox-proxy/`.** What changes:

- **`start` succeeds whether or not any certificate exists.** It binds port 80
  and port 443 and serves; certificates arrive when they arrive ([[0006]]).
  Starting no longer requires the network, a token, or a prior manual step. It
  does require a build when the sources are newer than the binary; [[0005]]
  explains why that check lives here rather than in the `Dockerfile`.
- **`reload` sends `SIGHUP` and swaps in place.** The process re-reads the
  declaration file, validates it, and only then replaces the routing table and
  the certificate allow-list atomically. Listeners stay bound, in-flight
  requests finish against the configuration they started with, established
  connections are not closed, and the certificate cache and signing key are
  untouched. Newly declared hostnames begin issuance asynchronously.
- **A reload that does not validate changes nothing.** The running configuration
  stays in place, the reason is printed, and the exit status is non-zero.
- `stop` stops the proxy only; the devbox and every backend keep running.

### Ports 80 and 443 without running as root

Traefik was started under `sudo`. The replacement is given
`cap_net_bind_service` after each build and runs as the user, because the state
directory is no longer only certificates: it holds the signing key, the GitHub
credentials and certmagic's storage, and mode 600 means something quite
different when the owner is `root` and the person reading it is not. Running as
the user keeps `status`, the key and the credentials ordinarily accessible, and
confines `sudo` to a single `setcap` call at build time.

### How results get back to the shell

`SIGHUP` is asynchronous, so sending it proves nothing about whether the new
configuration was accepted. Rather than open a control socket, **`reload` runs
`check` synchronously first** — if the declaration file does not validate it
exits non-zero without signalling anything — and the process validates again
when it receives the signal, so a file that changes in between still cannot
take anything down.

`status` reads from disk for the same reason: the pid file for liveness,
certmagic's storage for expiry dates, and a small state file the process writes
after each renewal attempt for the last result ([[0006]]). A control socket
would answer nothing at all while the process is stopped, which is exactly when
"when does this expire, and did the last renewal fail?" is most worth asking.

### Why in-process rather than validate-then-restart

Restarting is cheaper to write and less costly here than it would be elsewhere:
the cookies are self-contained so nobody is logged out ([[0007]]), and
certificates are read back from disk so Let's Encrypt is not contacted
([[0006]]). What a restart does break is a response in progress. The main
workload is `llama-server`, whose responses stream for minutes, and publishing a
second service would abort whatever the first one was generating.

That is the failure [[0004]] was written against: a publishing step with a
visible cost is a publishing step that gets postponed, and the servers stay as
raw HTTP on a high port. Making `reload` free to run is what keeps it cheap
enough to use.

## Consequences

- **Adding a service is invisible to the services already running.** No dropped
  connection, no interrupted stream, no new login.
- **Starting is unconditional**, so `entrypoint.sh` can call it without
  qualification and a freshly built devbox publishes as soon as its declaration
  file names something. [[0001]]'s property that the devbox comes up regardless
  is kept, and strengthened: previously the proxy was the part that would not
  start, now it starts and reports what it is missing.
- **The swap has to be written correctly.** The routing table and the allow-list
  are replaced as one value behind a pointer, not mutated field by field; a
  request that has already been routed completes against the configuration it
  was routed by. This is the part of the change most worth a test.
- **A broken declaration file cannot cost anything that is already working.**
  The guard [[0004]] introduced for a different reason survives with a better
  one.
- **Nothing listens for control traffic.** The only sockets bound are 80 and
  443; everything the shell needs to know is a file.
- `restart` remains available for the cases a reload genuinely cannot cover —
  a new binary, or a change to something read only at startup, such as the
  GitHub credentials.
