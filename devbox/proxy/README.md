# Publishing devbox HTTP servers

Puts `llama-server` and friends on `https://<name>.<zone>`, behind a GitHub
login, without either of them knowing about it.

Each devbox has a zone of its own — **anietta is `oeilvert.dev`, boucherie is
`poissonnerie.dev`** — and reads only the declaration file named after its own
hostname. So a name means something different on each box instead of clashing:
`llama` on anietta is `llama.oeilvert.dev`, `llama` on boucherie is
`llama.poissonnerie.dev`, and both can exist at once. The examples below use
boucherie's zone; substitute your own.

```
browser ──TLS──▶ devbox :443 ──▶ 127.0.0.1:<port>
                 │
                 ├─ certificate from Let's Encrypt, obtained and renewed here
                 ├─ session cookie checked, or the visitor is sent to
                 │  auth.<zone>, which runs the GitHub login
                 └─ one process: devbox-proxyd
```

Nothing is in front of the devbox. Cloudflare holds one wildcard `AAAA` record
and answers DNS queries for it; that is the entire dependency. There is no
proxy, no Access application, and no API token anywhere on this machine.

The reasoning is in [`docs/adr/`](../../docs/adr/): 0005 the shape, 0006 the
certificates, 0007 the login, 0008 the process. Records 0001 to 0003 describe
the arrangement this replaced and are marked superseded.

## What is here

| | |
|---|---|
| `services.<hostname>.yaml` | the declaration file — the only thing edited by hand |
| `bin/devbox-proxy` | `start` / `stop` / `restart` / `reload` / `status` / `check` / `build`; `entrypoint.sh` calls `start` |
| `proxyd/` | the proxy itself: TLS, the GitHub login, and the reverse proxy |
| `test/` | `bats devbox/proxy/test` for the wrapper; `go test ./...` in `proxyd/` for the rest |

Adding a service by hand is below. An agent that has just started a server does
it through the `devbox-publish` skill in `skills/` instead, which is the same
two steps with the arguments checked first.

Runtime state lives in `~/.config/devbox-proxy` — certificates, the signing key,
the GitHub credentials, the compiled binary, logs, pid file. It is under
`$HOME`, which is the host's, so it survives the container being rebuilt.

## One-time setup

Two of these are dashboard work; the third is one file.

### 1. A GitHub OAuth App

github.com → Settings → Developer settings → OAuth Apps → New OAuth App.

| Field | Value |
|---|---|
| Application name | anything, e.g. `boucherie devbox` |
| Homepage URL | `https://auth.poissonnerie.dev` |
| Authorization callback URL | `https://auth.poissonnerie.dev/callback` |

**The callback is `auth.<zone>` and nothing else.** One application covers every
service on the box, now and later, because every login happens on that one host
and is handed to the service afterwards (`docs/adr/0007`). Publishing a service
never involves this page again.

Keep the Client ID, and generate a client secret — it is shown once.

### 2. The credentials file

```bash
mkdir -p ~/.config/devbox-proxy
cat > ~/.config/devbox-proxy/github.yaml <<'EOF'
client_id: Iv1.xxxxxxxxxxxx
client_secret: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
EOF
chmod 600 ~/.config/devbox-proxy/github.yaml
```

The proxy refuses to read it if other accounts can. This is the only secret that
has to be placed by hand: the token-signing key is generated on first use, and
certificates arrive on their own.

### 3. One DNS record

In the Cloudflare dashboard, on the zone:

| Type | Name | Content | Proxy status |
|---|---|---|---|
| `AAAA` | `*` | the devbox's global IPv6 | **DNS only (grey cloud)** |

The address is the one `start-cuda` / `start-rocm` pass to `docker run --ip6`.

**Grey cloud matters.** With the orange cloud on, Cloudflare intercepts port 80
and the ACME challenge never reaches the devbox, so no certificate is ever
issued (`docs/adr/0006`).

Nothing else in the zone is touched, and nothing on the devbox ever writes to
Cloudflare again.

### 4. Ports 80 and 443 reachable

Port 443 serves everything. Port 80 answers ACME challenges and redirects the
rest to HTTPS; it has to be open or no certificate can be issued.

`bin/devbox-proxy build` gives the binary `cap_net_bind_service` so it can bind
both as your own user — the one `sudo` in the whole arrangement, and only at
build time.

## Adding a service

Suppose `llama-server` is listening on `127.0.0.1:8081` and it should be at
`https://llama.poissonnerie.dev` for you and anyone in the `acme` GitHub org.

```yaml
# devbox/proxy/services.boucherie.yaml
services:
  - name: llama
    port: 8081
    auth: required
    viewers:
      logins:
        - yuanying
      github_orgs:
        - acme
```

Then:

```bash
devbox/proxy/bin/devbox-proxy reload
git add -A devbox/proxy && git commit -m 'Publish llama'
```

Or, the same thing without editing YAML:

```bash
~/.claude/skills/devbox-publish/bin/devbox-publish \
    publish --name llama --port 8081 --github-org acme
```

That checks the arguments, checks something is actually listening on the port,
writes the block and reloads. There is no third step and no token: adding a
service touches nothing outside this devbox.

The first request to `https://llama.poissonnerie.dev` waits a few seconds while
Let's Encrypt issues a certificate. Every request after that is served from the
cached one, and renewal happens on its own about thirty days before expiry.

Names are a **single label**. `llama` is fine, `llama.gpu` is rejected — the
wildcard `AAAA` record covers exactly one level. Namespace in the name
(`gpu-llama`) instead. `auth` is reserved.

Viewers are **GitHub account names**, not email addresses. A login is what the
account is; an address can be unverified, one of several, or changed quietly.

`auth: none` publishes something with no login at all. It is then genuinely
public: the IPv6 address is in DNS and the hostname appears in Certificate
Transparency logs, so "nobody will find it" is not a property it has.

Removing a service is the reverse: delete the block and reload, or
`devbox-publish unpublish --name llama`. The wildcard record stays — it always
covered every label — but nothing answers on that name, and its certificate
simply stops being renewed.

## Checking that it works

**The devbox comes up without any of this.** There is no certificate to be
missing any more, so the only thing that stops the proxy starting is having no
declaration file:

```bash
docker restart devbox && docker logs devbox 2>&1 | grep -i proxy
```

**The front door.** Open `https://llama.poissonnerie.dev` in a browser. Expect a
redirect to `auth.poissonnerie.dev`, GitHub, a consent screen the first time,
and then the service. `~/.config/devbox-proxy/log/proxy.log` records what
happened.

**There is no back door to check.** The login is verified by the same process
that serves the request, so it holds whether the request arrived through the
hostname or straight at the IPv6 address. That is the difference from the
arrangement `docs/adr/0003` had to shore up separately.

```bash
curl -sk -o /dev/null -w '%{http_code}\n' \
    --resolve 'llama.poissonnerie.dev:443:[2405:6581:8580:302::151]' \
    https://llama.poissonnerie.dev/
```

Expect **302** to the auth host. `-k` is not needed — the certificate is
publicly trusted now — but it does no harm.

**Everything at once:** `devbox-proxy status`. It prints every hostname, when
its certificate expires, and what the last renewal attempt did. It answers
while the proxy is stopped, too.

## When it goes wrong

| Symptom | Where to look |
|---|---|
| The browser cannot connect at all | is the proxy running? `devbox-proxy status`. Then whether `:443` reaches the devbox from outside |
| A certificate warning, or a name that never gets one | `devbox-proxy status` for the last attempt and its reason. Then: is the record grey cloud, and does port 80 reach the box? |
| `status` says `pending` for a name | nothing has visited it yet, or the first attempt is still running. Normal on a fresh devbox |
| The login loops back to GitHub | the callback URL in the OAuth App is not exactly `https://auth.<zone>/callback` |
| "You are signed in as X, who is not on the list" | X is the GitHub account you are actually signed in to. Add it to `viewers.logins`, or sign in as someone who is |
| 502 from a name that used to work | the backend stopped. `devbox-proxy status` is fine, the service behind the port is not |
| `reload` exits non-zero | the declaration file does not validate, and the message says why. Whatever was running is still running |

## Tests

```bash
bats devbox/proxy/test          # the wrapper: building, starting, reloading
cd devbox/proxy/proxyd && go test ./...   # everything else
```

From the repository root, `bats -r .` runs the wrapper's tests and the
publishing skill's. The Go tests cover the declaration file, token forgery and
expiry, a cookie replayed against another service, the GitHub exchange against a
stand-in, the routing table being replaced under load, and what `status` says.
What they do not cover is Let's Encrypt itself and a real browser login; those
are the steps above.
