# 0010. Admit API clients with a bearer token, signed with a second key

- Date: 2026-08-21
- Status: Accepted

## Context

[[0007]] decided how a browser gets in, and every part of it assumes a browser:
a redirect to `auth.<zone>`, a round trip through GitHub's consent screen, a
cookie set on the way back. But the workload behind these names is an HTTP API
— `llama-server` speaks OpenAI's protocol — and the things that want to speak it
are not browsers. A client handed a 302 follows it, arrives at GitHub, and
reports whatever HTML came back as an error. There is no way to reach a
published API from a script at all.

Three things have to be decided.

**What a non-browser presents.** `Authorization: Bearer` is what every client
that might call this API already sends. Nothing else is worth considering; the
question is what goes inside it and what vouches for it.

**What signs it.** [[0007]] has a signing key and a rule that comes with it:
rotating that key is the only revocation there is. A long-lived token handed to
a script is a much likelier thing to leak than a browser cookie, and it is the
kind of leak that is noticed weeks later.

**What an unauthenticated request gets.** Today it is always a redirect. A
bearer token that fails to verify cannot usefully be answered with one.

## Decision

### A third token kind, scoped like the cookie

`KindAPI` joins `KindCookie` and `KindHandover`, carried as
`Authorization: Bearer <token>` and holding the same payload: subject, service,
expiry. The service name is inside the signature, so — exactly as with the
cookie — a token issued for one service does not open another.

Expiry defaults to 90 days and can be set at issue, including to nothing at all.
The default is a bound on tokens that are forgotten rather than a security
control; the control is below.

### A second signing key

`api.key` sits next to `session.key` and is generated on first use the same way
([[0007]]). Nothing else about it is new.

Sharing the one key would have been less code, and is rejected. Rotation is the
only revocation this design has, so with a shared key a single leaked API token
would be paid for by signing every browser out of every service — a price high
enough that the lever would not get pulled. Two keys make the two revocations
independent: the API tokens die, the sessions do not notice.

Rotation is `rm ~/.config/devbox-proxy/api.key` and then `devbox-proxy reload`.
That requires SIGHUP to re-read the key and not only the declaration, and the
signer to be swapped the way the routing table already is — which is the point.
A revocation must not cut the response somebody has been streaming for four
minutes ([[0008]]).

### Two ways to get one

**In a browser:** `GET /_devbox-auth/token` on the service host returns the
token as one line of `text/plain`. The session cookie is already proof of
identity, so there is nothing to ask and nothing to confirm; this is the same
shape as the auth host's own index page. Each visit mints a fresh token and
records nothing, so an earlier one keeps working until it expires.

**On the box:** `devbox-proxy token --service llama --user yuanying [--ttl]`.
There is no GitHub round trip, so the name is not checked against `viewers`.
Whoever can read the signing key can already sign anything they like; a check
there would express a rule that the file permissions do not, and it would rule
out the useful case of naming a token after what it is (`ci`, `agent`) rather
than after a person.

### 401 only when the request asked for it

An `Authorization` header that does not verify is answered with `401` and
`WWW-Authenticate: Bearer`. A request without the header is redirected to the
auth host, unchanged from [[0007]]. The rule is one line long, and no browser
behaves differently than it did.

Content negotiation was considered as a second signal — treating a request that
does not accept HTML as an API call — and rejected. It answers a narrow case, a
client that forgot its token, by making the rule a heuristic that has to be
explained.

A header the proxy verified is removed before the request is forwarded, and
`X-Devbox-User` is set from it, which is what already happens for a cookie. A
header the proxy did not consume — on an `auth: none` service — is passed
through untouched, so a backend that wants its own `Authorization`, such as
`llama-server --api-key`, still gets it.

## Consequences

- **Publishing an API costs nothing new.** `services.<hostname>.yaml` gains no
  vocabulary: `auth: required` now means both a browser login and a bearer
  token, and [[0004]]'s "adding a service is cheap" is untouched.
- **Revocation is all-or-nothing.** There is no ledger, so an outstanding token
  cannot be listed, individually revoked, or even recognised — including the
  leaked one. This is [[0007]]'s trade taken a second time, and it is a worse
  bargain here, because a token in a dotfile lives longer and travels further
  than a cookie. Expiry is the only thing bounding it. If these are ever handed
  to somebody else in `viewers`, this is the decision that has to be revisited
  first.
- **Anyone who can read `api.key` can mint any identity**, so `X-Devbox-User` on
  an API request attests to the box's file permissions, not to GitHub. It is
  worth no more than that, and a backend should not treat it as more.
- **The browser route mints on GET.** A link somebody is tricked into opening
  cannot be read back by whoever sent it — the response is same-origin — but it
  does add a live token that nobody knows about. The absence of a ledger is what
  makes that unobservable.
- **Two kinds of forgery are now impossible for two independent reasons**: the
  kind is in the signed payload, and the keys differ. A session cookie replayed
  as a bearer token fails both checks.
- **`auth: none` is unchanged.** No token is asked for and none is consumed, so
  what such a service sees is exactly what it saw before.
