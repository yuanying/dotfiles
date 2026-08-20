# Publishing devbox HTTP servers

Puts `llama-server` and friends on `https://<name>.<zone>`, behind a GitHub
login, without either of them knowing about it.

Each devbox has a zone of its own — **anietta is `oeilvert.dev`, boucherie is
`poissonnerie.dev`** — and reads only the declaration file named after its own
hostname. So a name means something different on each box instead of clashing:
`llama` on anietta is `llama.oeilvert.dev`, `llama` on boucherie is
`llama.poissonnerie.dev`, and both can exist at once. The examples below use
anietta's zone; substitute your own.

```
browser ──TLS──▶ Cloudflare edge ──TLS──▶ devbox :443 ──▶ 127.0.0.1:<port>
                 Access checks              Traefik checks
                 the GitHub login           the token Access issued
```

Cloudflare terminates the public certificate and runs the login. The devbox's
own global IPv6 is the origin, so the second leg needs a certificate Cloudflare
trusts, and — because that address is reachable by anyone who finds it — a check
that the request really came through Access. The reasoning behind each of those
is in [`docs/adr/`](../../docs/adr/): 0001 the shape, 0002 the certificate,
0003 the JWT check, 0004 the declaration file.

## What is here

| | |
|---|---|
| `services.<hostname>.yaml` | the declaration file — the only thing edited by hand |
| `bin/devbox-proxy` | `start` / `stop` / `restart` / `reload` / `status`; `entrypoint.sh` calls `start` |
| `bin/generate-traefik-config.sh` | declaration file → Traefik configuration |
| `bin/issue-origin-cert.sh` | issue (or re-issue) the origin certificate |
| `bin/sync-cloudflare.sh` | reconcile DNS records and Access applications |
| `bin/cf-access-forwardauth` | the JWT check Traefik calls on every request |
| `test/` | `bats devbox/proxy/test`; `bats -r .` from the repository root runs these and the skill's |

Adding a service by hand is below. An agent that has just started a server does
it through the `devbox-publish` skill in `skills/` instead, which is the same
three steps with the arguments checked first.

Runtime state lives in `~/.config/devbox-proxy` — certificates, generated
configuration, logs, pid files. It is under `$HOME`, which is the host's, so it
survives the container being rebuilt.

## One-time setup

Steps 1 to 3 are dashboard work and cannot be scripted from here.

### 1. A GitHub OAuth App

github.com → Settings → Developer settings → OAuth Apps → New OAuth App.

| Field | Value |
|---|---|
| Application name | anything, e.g. `Cloudflare Access` |
| Homepage URL | `https://<team>.cloudflareaccess.com` |
| Authorization callback URL | `https://<team>.cloudflareaccess.com/cdn-cgi/access/callback` |

`<team>` is the Cloudflare Zero Trust team name. Keep the Client ID, and
generate a client secret — it is shown once.

### 2. GitHub as an identity provider in Zero Trust

Zero Trust dashboard → Settings → Authentication → Login methods → Add new →
GitHub. Paste the App ID and the client secret from step 1, and use **Test
connection** before saving.

Cloudflare asks GitHub for `Organizations and teams (read-only)` and
`Email addresses (read-only)`, which is why a policy can be written against
either a GitHub organisation or an email address.

Note the team domain while here — Settings → Custom Pages shows it, and it is
the host in the URLs above. It goes into `team_domain` in the declaration file.
The origin uses it to know which team's signatures to accept.

### 3. SSL mode: Full (strict)

Dashboard → the zone → SSL/TLS → Overview → **Full (strict)**.

This is **zone-wide**: every other origin behind the zone must already present
a certificate Cloudflare trusts, or it breaks when the mode changes. Both zones
were empty when they were picked — no `A`, `AAAA`, `CNAME` or `MX` record in
either — so today there is nothing else to break. Publishing anything else from
one of these zones later means giving it a trusted certificate first.

Full alone is not a substitute — it accepts any certificate the origin offers,
including a forged one, which is the whole reason not to use a self-signed
certificate here (`docs/adr/0002`).

### 4. API tokens

Two scripts want a token, and they want different things. Either make one token
with the union, or make two and use each where it belongs. Create them at
dashboard → My Profile → API Tokens → Create Token → Custom token.

For `issue-origin-cert.sh`:

| Scope | Permission |
|---|---|
| Zone → this host's zone | SSL and Certificates → Edit |

For `sync-cloudflare.sh`:

| Scope | Permission |
|---|---|
| Zone → this host's zone | Zone → Read |
| Zone → this host's zone | DNS → Edit |
| Account → the account holding the zone | Access: Apps and Policies → Edit |
| Account → the account holding the zone | Access: Organizations, Identity Providers, and Groups → Read |

The last one is only needed if a service lists `github_orgs`: a GitHub
organisation rule has to name the identity provider it belongs to, so the script
looks it up.

Tokens are passed in the environment for the length of one run and are never
written to disk. `docs/adr/0002` explains why that is worth the inconvenience.

### 5. Issue the origin certificate

```bash
cd ~/dotfiles
$EDITOR devbox/proxy/services.$(hostname -s).yaml   # fill in team_domain
CLOUDFLARE_API_TOKEN=... devbox/proxy/bin/issue-origin-cert.sh
```

This writes `~/.config/devbox-proxy/certs/origin.{pem,key}` for `*.<zone>` plus
the apex, valid for fifteen years. The zone comes from the declaration file, so
each devbox gets a certificate for its own and neither can stand in for the
other — boucherie needs its own run of this.

**Cloudflare shows the private key once and keeps no copy.** There is nothing to
download later. Losing it is not a disaster — re-running this script issues a
new one — but there is no other way back. Nothing will warn about expiry either;
`devbox-proxy status` prints the date.

## Adding a service

Suppose `llama-server` is listening on `127.0.0.1:8081` and it should be at
`https://llama.oeilvert.dev` for you and anyone in the `acme` GitHub org.

```yaml
# devbox/proxy/services.anietta.yaml
services:
  - name: llama
    port: 8081
    auth: required
    aud: ""            # sync-cloudflare.sh fills this in
    viewers:
      emails:
        - you@example.com
      github_orgs:
        - acme
```

Then:

```bash
CLOUDFLARE_API_TOKEN=... devbox/proxy/bin/sync-cloudflare.sh --dry-run   # look first
CLOUDFLARE_API_TOKEN=... devbox/proxy/bin/sync-cloudflare.sh
devbox-proxy reload
git add -A devbox/proxy && git commit -m 'Publish llama'
```

Or, the same thing without editing YAML:

```bash
~/.claude/skills/devbox-publish/bin/devbox-publish \
    publish --name llama --port 8081 --github-org acme
```

That checks the arguments, checks something is actually listening on the port,
writes the block, and then goes as far as it can: with a token in the
environment it syncs and reloads, and without one it stops after the file and
prints what is left. It skips the reload when the configuration does not
generate — an authenticated service has no audience tag until the sync runs, and
reloading would stop Traefik and then fail to start it, taking down whatever was
already working.

The sync creates the proxied `AAAA` record and the Access application, and
writes back the audience tag Cloudflare generated. That tag has to be committed:
the origin checks it on every request, and without it the next `reload` refuses
to generate a configuration at all.

Names are a **single label**. `llama` is fine, `llama.gpu` is rejected — free
Universal SSL covers one level of subdomain and a wildcard Origin CA certificate
covers exactly one level too. Namespace in the name (`gpu-llama`) instead.

`auth: none` publishes something with no login at all. It is then genuinely
public, at the hostname and at the origin address alike; that is what the
setting means.

Removing a service is the reverse: delete the block, then
`sync-cloudflare.sh --prune`, then `devbox-proxy reload`. Without `--prune`
nothing is ever deleted from Cloudflare. Even with it, only names of the form
`<label>.<zone>` in *this host's* zone that the file no longer mentions, and
only ones that are proxied — a grey-cloud record is never touched.

## Checking that it works

**The devbox comes up without any of this.** Move the certificate aside and
restart the container; it should start normally, with `devbox-proxy` saying on
stderr that it found no certificate and starting nothing.

```bash
mv ~/.config/devbox-proxy/certs ~/.config/devbox-proxy/certs.away
docker restart devbox && docker logs devbox 2>&1 | grep -i proxy
mv ~/.config/devbox-proxy/certs.away ~/.config/devbox-proxy/certs
```

**The front door.** Open `https://llama.oeilvert.dev` in a browser. Expect a
Cloudflare Access page, GitHub, a consent screen the first time, and then the
service. `~/.config/devbox-proxy/log/forwardauth.log` records who was let in.

**The back door is shut.** Ask the origin directly, bypassing Cloudflare:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' \
    --resolve 'llama.oeilvert.dev:443:[2405:6581:8580:310::153]' \
    https://llama.oeilvert.dev/
```

Expect **403**. A 200 means the check is not running — look at
`forwardauth.log` and at whether the router actually got its middleware. `-k` is
needed because the origin certificate is signed by Cloudflare's Origin CA, which
no public trust store carries; that is by design.

**Everything at once:** `devbox-proxy status`.

## When it goes wrong

| Symptom | Where to look |
|---|---|
| Cloudflare error 526 | the certificate does not verify: is SSL mode Full (strict), and is the certificate the one issued for this zone? |
| Cloudflare error 521/522 | Traefik is not listening: `devbox-proxy status`, then `~/.config/devbox-proxy/log/traefik.log` |
| Everything returns 403 | `forwardauth.log`; usually a stale `aud` after the Access application was recreated |
| Authenticated routes return 500 | the verifier is not running. It fails closed on purpose |
| `devbox-proxy start` says nothing happened | no certificate, or no declaration file for this hostname |

## Tests

```bash
bats devbox/proxy/test
```

They cover the declaration file → Traefik configuration transformation, the
validation rules, the start/stop behaviour, certificate issuance against a
stand-in API, and the JWT check — mostly its negative cases. What they do not
cover is Cloudflare itself and a real browser login; those are the steps above.
