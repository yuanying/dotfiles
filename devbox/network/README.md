# Docker networks on a devbox host

Every devbox host has the same two user-defined bridge networks. Why they are
shaped like this is `docs/adr/0012`.

| | `v6net` | `sdnet` |
|---|---|---|
| Used by | the devbox | the app containers (`devbox/apps/`), and the devbox as its second network |
| Driver | bridge | bridge |
| IPv4 | `172.18.0.0/16`, gateway `172.18.0.1` | `172.30.0.0/24`, gateway `172.30.0.1` |
| IPv6 | the host's global `/64` | none |
| Internal | no | no — the apps download packages, extensions and models |

Everything in that table except the IPv6 row is the same on every host and is
written once, in `networks.env`. The IPv6 subnet, its gateway and the devbox's
fixed address in it are the only things that differ, and they are the only
things in `hosts/<hostname>.env`. The devbox's address there is also the one
the proxy's wildcard `AAAA` record points at (`devbox/proxy/README.md`).

The devbox joins `sdnet` with a gateway priority below `v6net`'s, so its
default route stays on `v6net` and nothing about how it reaches the outside
changes. It is on `sdnet` only to reach the apps by container name.

Other networks a host may have are not part of this: the default `bridge`
(its IPv6 settings come from the daemon's `daemon.json`), and `kind`, which
kind makes for itself.

## Setting up a host

1. Add `hosts/<hostname>.env` with the three IPv6 values. The subnet is the
   global `/64` the router delegates to that host; pick the devbox's address in
   it and add the `AAAA` record for it if the host will publish anything.
2. Run `setup-networks` on the host, or in any devbox there — it only talks to
   the Docker socket. Without an argument it uses the short hostname. Try it
   with `--dry-run` first: that prints the `docker network create` commands for
   whatever is missing and changes nothing.
3. Start the devbox with the start script for the host's backend. `start-cuda`
   and `start-rocm` each name their host at the top, read that host's file and
   put the devbox on both networks; a new host needs its name there, or a
   script of its own. Run step 2 first — `docker run` fails if either network
   is missing.

`setup-networks` is safe to run again. A network that is already there and
matches is reported as `ok`. One that is there but differs is reported with the
difference and left alone, and the exit status is non-zero; the other network
is still created if it was missing.

## Adding sdnet to a devbox that is already running

The start scripts only take effect when the devbox is created. A devbox created
before `sdnet` existed joins it without being restarted:

```bash
docker network connect --gw-priority -1 sdnet devbox
```

`docker inspect devbox` then shows both networks, with `GwPriority` `-1` on
`sdnet`. `docker network disconnect sdnet devbox` undoes it.

## When setup-networks reports a difference

A network cannot be changed in place; it has to be removed and made again,
and it cannot be removed while a container is attached. For `sdnet` that means
the app containers and the devbox's second interface, which is cheap:

1. `docker compose -f ~/dotfiles/devbox/apps/compose.<hostname>.yaml down`
2. `docker network disconnect sdnet devbox`
3. `docker network rm sdnet`, then `setup-networks`
4. Connect the devbox again as above, and bring the apps back with `up -d`.

For `v6net` it means the devbox itself, and the connection you are working
through goes down with it. Do it from the host's console, not from inside the
devbox:

1. Note what the difference was — `setup-networks` prints the actual values,
   which are what to recreate if the change has to be undone.
2. `docker stop devbox`, then `docker network disconnect v6net devbox`.
3. `docker network rm v6net`, then `setup-networks`.
4. `docker network connect --ip6 <DEVBOX_IP6 from the host file> v6net devbox`,
   then `docker start devbox`.

Any other container attached to `v6net` has to be disconnected and connected
again the same way.

As of this writing both hosts' `v6net` already match, so neither needs this.
