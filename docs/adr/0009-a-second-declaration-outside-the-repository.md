# 0009. Let a second declaration live outside the repository

- Date: 2026-08-21
- Status: Accepted

## Context

[[0004]] makes `services.<hostname>.yaml` the source of truth, and [[0007]] put
GitHub account names in it. `yuanying/dotfiles` is public. Two things follow
that were not thought about when the file was designed, because at the time the
only viewer was the person who owns the repository and the only services were
ones there was no reason to hide.

**Letting somebody in means publishing their name.** Granting access to one more
person commits their GitHub account to a public repository, next to the address
of a machine and the name of a service they can reach on it. Nobody consents to
that by accepting an invitation, and the arrangement does not require it.

**Publishing a service means announcing it.** Certificate Transparency already
leaks hostnames ([[0006]]), so a service cannot be hidden — but its port, its
purpose, and the fact that this particular box runs it need not be in a
public git history for as long as the repository exists. Some things are worth
running and not worth explaining.

What is in the declaration file for good reasons is the rest: a service's
shape, reviewed and versioned, reproducible on a rebuilt box. The problem is
not that the file is public. It is that it is the *only* place to say anything.

`~/.config/devbox-proxy` is already the answer to this shape of question. It is
outside the repository, it survives the container being rebuilt, and the signing
key and GitHub credentials are there for the same family of reason ([[0007]]).

## Decision

**A second declaration, `~/.config/devbox-proxy/services.local.yaml`, is merged
over the first.** It has the same schema as `services.<hostname>.yaml` minus the
zone.

```yaml
# ~/.config/devbox-proxy/services.local.yaml
services:
  # add somebody to a service the repository declares
  - name: sd-webui
    viewers:
      logins:
        - someone

  # publish something the repository never hears about
  - name: private
    port: 9000
    auth: required
    viewers:
      logins:
        - yuanying
```

The merge rules are the shortest ones that make both uses work:

| | |
|---|---|
| an entry naming a declared service | updates it |
| an entry naming anything else | is a new service, published as if declared |
| `port`, `auth` | the overlay wins when it sets them, otherwise the declaration stands |
| `viewers` | **always added**, never replaced |
| `zone` | not accepted here at all |

**Viewers add rather than replace** because the two files are two halves of one
guest list, not two competing answers: somebody the declaration names must not
lose access because the overlay happened to mention the service. Names are
merged by GitHub's rules, so `Someone` and `someone` are one person.

**`port` and `auth` override** because the things that differ between one box
and the next are exactly those: a port that collides with something else running
locally, a service turned open for an afternoon. Making those require a commit
to a public repository is the friction this record exists to remove.

**The zone is refused** because changing it would move every hostname, every
certificate and the auth host at once. That is a different devbox, not an
override.

### Validation happens after merging, not before

A declaration and an overlay are only meaningful together: a port collision can
be created by either file alone, and neither is wrong by itself. So parsing
checks syntax, and every rule about what a configuration *means* runs once, on
the merged result. `check` therefore validates exactly what `serve` enforces.

One rule had to be relaxed to make this work. [[0004]] refused a declaration
where a service asked for a login and named no viewers, on the grounds that it
locks out everyone; that check cannot run against half the configuration, and
requiring the overlay to exist would defeat the point.

**It becomes a warning.** `check`, `status` and container startup all report a
service that admits nobody, and the proxy starts anyway — the same call [[0008]]
makes about every other missing precondition, for the same reason: refusing to
run publishes nothing at all, including the services that are fine.

The same reasoning corrected an inconsistency this exposed. Missing GitHub
credentials used to abort startup whenever any service asked for a login. They
no longer do: certificates still arrive, `auth: none` services still work, and a
service that wants a login explains what is missing when somebody tries — a far
better place to find out than a container log nobody is reading.

### Rejected: a viewers-only overlay

The first version of this record allowed only `viewers` to be overridden, on the
grounds that the shape of a service belongs under review. It is a smaller
change and it is a real distinction — but it answers half the question, and a
second file with a second schema would have been needed for the other half.
One file with the schema that already exists is less to learn and less to
maintain.

### Rejected: a directory of fragments

`services.d/*.yaml` would let one service be one file. It needs a defined load
order and a precedence rule for duplicates, which is more machinery than a
handful of services justifies. One file, merged in the order written.

## Consequences

- **Letting somebody in, or running something privately, no longer touches the
  repository** — no commit, no announcement, no review.
- **The configuration is in two files, and `devbox-proxy check` is the only
  thing that knows the answer.** It prints which files it merged and the
  resulting viewer count per service. Reading the declaration file alone no
  longer tells you what is published or who can reach it. This is the real cost
  of the decision.
- **A typo in the overlay can silently publish something.** An entry naming a
  service that does not exist used to be catchable as a mistake; now it is a
  new service. A missing `port` still catches the common case, but
  `nmae: sd-webui` with a port creates a service called `nmae` rather than
  complaining. `check` lists everything it will publish, which is the mitigation.
- **The overlay is not backed up and has no history.** It survives image
  rebuilds because `$HOME` is the host's, but nothing versions it. Losing it
  loses the services and viewers that existed only there — recoverable by
  retyping, and not a disaster.
- **No file mode is enforced on it**, unlike the signing key and the GitHub
  credentials. Account names and port numbers are not secrets; they are outside
  the repository because it is published, which is privacy rather than secrecy.
- **A service that admits nobody now starts.** A deliberate loosening, and the
  reason the warnings exist.
- `devbox-publish` still writes to the declaration file only. Publishing
  privately is a hand edit; if that becomes routine, the skill should learn a
  flag for it.
