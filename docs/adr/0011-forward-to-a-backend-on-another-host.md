# 0011. Forward to a backend on another host

- Date: 2026-09-10
- Status: Accepted

## Context

[[0005]] made the proxy one process that connects every service to
`127.0.0.1:<port>`. That was the whole world at the time: everything published
ran inside the devbox, started by hand in a terminal pane.

Some of those servers are now long-running applications — an image generator,
its viewer, a tagging tool — that should come back on their own after a reboot
and should not go down when the devbox container is recreated. The natural home
for them is a container each, with `restart: always`, on a user-defined docker
network the devbox also joins. From the devbox, such a container is reachable by
its name through docker's embedded DNS. It is not on the devbox's loopback, so
the proxy as it was could not reach it.

The things that had to stay true:

- every existing declaration means exactly what it meant before;
- the overlay of [[0009]] can say anything the declaration can;
- `check` stays the single answer to "what is published", so it has to say
  where each name goes;
- a mistake in the file is reported by `check`, with the reason, not discovered
  as a 502 ([[0004]], [[0008]]).

## Decision

**A service takes an optional `host`: where its backend listens.** It is either
a hostname — typically a container name — or a bare IP address. Left out, it is
`127.0.0.1`, so no existing file changes meaning. The proxy connects to
`<host>:<port>` and nothing else about a request changes: the scheme is http,
the path is passed through, and the backend still sees the public name in
`Host`.

**The name is resolved when a connection is made**, not when the file is read.
A container recreated with a new address is found again without a reload, and
a container that happens to be stopped does not make `check` or `reload` fail —
it makes that one service answer 502, the same as a stopped loopback server.

**The overlay overrides `host` the way it overrides `port` and `auth`**
([[0009]]): set, it wins; absent, the declaration stands. Where a backend runs
is exactly the kind of fact that differs between one box and the next.

**Ports collide only on the same host.** Two containers each listening on
`:8080` is ordinary. Two services pointing at the same `host:port` remain an
error. Hosts are compared case-insensitively, and the default is the literal
`127.0.0.1`, so writing it out is the same as leaving it out. Aliases such as
`localhost` are not recognised as the same host — nothing resolves names at
check time, by the rule above.

### What `host` accepts

| | |
|---|---|
| a hostname | labels of letters, digits, hyphens and underscores separated by dots; each label 1–63 characters, 253 in all. Underscores and upper case are allowed because docker container names can carry them |
| an IP address | IPv4, or IPv6 **without** brackets |
| left out | `127.0.0.1` |

Refused, each with its own explanation:

| | why |
|---|---|
| blank (whitespace only) | a typo, not a request for the default; leaving the key out is how to ask for that |
| a scheme (`http://…`) | the proxy only speaks http to a backend; a scheme suggests otherwise |
| a port (`sd-webui:7860`) | the port has its own key; two places to say it is one too many |
| brackets (`[fd00::2]`) | brackets are URL syntax; the file holds a bare address and the proxy adds them |
| an IPv6 zone (`fe80::1%eth0`), a path, spaces, empty labels, a trailing dot | not something the resolver should be handed |

Mistakes are named instead of tolerated because the alternative is a string
passed to the dialer that fails on the first request, with an error about DNS
rather than about the file.

### Rejected: an `upstream` URL instead of `host`

`upstream: http://sd-webui:7860` says everything in one key, and it is how many
proxies are configured. It would also mean a second way to give the port,
invite `https://` and paths the proxy does not implement, and change the schema
of every declaration or leave two schemas side by side. `host` next to `port`
extends what is already there.

### Rejected: bringing the containers to the devbox's loopback

A container can share the devbox's network namespace, or publish its port on
the host's loopback, and then `127.0.0.1` would still be right. The first ties
the container's lifetime to the devbox — recreating the devbox takes the
network namespace away — which is the thing moving to containers was meant to
avoid. The second puts the port on the docker host rather than in the devbox,
so it is not the devbox's `127.0.0.1` at all.

### Rejected: resolving or probing the host in `check`

`check` could look the name up, or even connect, and warn. It would make the
answer depend on what happens to be running at that moment, and `reload`
validates through the same path ([[0008]]) — a stopped container would then
block publishing anything else. What is running is `status` and the proxy log's
business.

## Consequences

- **Existing declarations are unchanged**, including the ones on other hosts
  that never use this.
- **`check` prints `host:port` for every service**, and `devbox-publish list`
  does too. `devbox-publish publish` gains `--host`, and its listen check goes
  to that host.
- **A backend on a shared network is reachable without the proxy** by
  everything else on that network. A loopback backend was reachable only from
  inside the devbox. The login is still enforced on every request that comes
  through the proxy, but a neighbour on the network can talk to the backend
  directly and set `X-Devbox-User` itself. The network should hold only the
  containers that need it, and a backend should not treat that header as proof
  of anything a neighbour could not also claim.
- **`host` can point anywhere the devbox can reach**, not only at containers —
  another machine on the LAN, for instance. That is not prevented; the
  declaration is reviewed, and the overlay is the owner's own file.
- **A name that does not resolve is a 502, logged with the resolver's error.**
  The usual cause is a container that is not running or not attached to a
  network the devbox is on.
