# 0012. Run the sd apps in containers on a bridge of their own

- Date: 2026-09-10
- Status: Accepted

Revised below (2026-09-13) for hosts whose network is declared with regied,
again the same day when poissonnerie moved too, and on 2026-09-19 when builds
stopped needing the host's network.

## Context

boucherie runs three web apps that are used every day: sd-webui (Forge Neo),
sd-viewer and tageditor. Each was started by hand in a herdr pane inside the
devbox, and each repository's CLAUDE.md said how. A restart of the devbox or
of the host left all three down until somebody noticed, and the instructions
for bringing them back were spread over three repositories.

They are published through proxyd ([[0005]]), which runs in the devbox. Until
[[0011]] it could only forward to `127.0.0.1`, so anything published had to be
a process inside the devbox.

The constraints the apps bring:

- **They are developed, not only used.** Each is a checkout under `$HOME` that
  is edited from the devbox, and an edit has to reach the running app without
  a rebuild of anything larger than the app itself.
- **sd-webui's environment is large and was built in the devbox.** Its venv is
  6.7 GB, made from a Python that asdf compiled in the devbox (Ubuntu 24.04),
  and it needs the GPU. Models are under `/mnt`.
- **What they write belongs to the user.** Generated images and datasets are
  read and edited from the devbox afterwards.
- **They do not need to be reachable from the internet directly.** proxyd is
  the way in, with a login in front ([[0007]]).

And the network the devbox is on was never written down. `v6net` was made by
hand on each host, with the host's global IPv6 `/64` and whatever IPv4 subnet
Docker chose at the time; nothing said what a new host should get.

## Decision

**Each app runs in its own container with `restart: always`, declared per host
in `devbox/apps/compose.<hostname>.yaml`, on a bridge network of its own that
the devbox also joins.**

- **The images are runtimes only.** The source, the venvs and the languages
  they were built from are the host's `$HOME`, mounted at the same path as in
  the devbox, along with `/mnt`. The containers run as UID 501, group `staff`,
  as the devbox user does. sd-webui's image is the CUDA runtime on Ubuntu
  24.04, for the glibc its Python was linked against. sd-viewer's is the Go
  toolchain, and it builds the checkout every time it starts. tageditor's is
  Node and uv, and it runs its two development servers side by side.
- **How each one starts is baked into its image.** The entrypoints are copied
  in at build time, and the arguments are in the compose file. Nothing a
  container runs refers back to the dotfiles checkout, so the one that built
  the image can go away. The compose project name is fixed so that any checkout
  manages the same containers.
- **The apps are on `sdnet`, an IPv4-only bridge, and nothing else.** The
  devbox joins it as a second network with a lower gateway priority than
  `v6net`, so its default route does not move. proxyd and `sdctl` reach the apps
  by container name.
- **Both networks are defined once for every host.** Names, drivers, IPv4
  subnets and options are the same everywhere (`devbox/network/networks.env`);
  a host's file holds only the IPv6 values for `v6net`. `setup-networks`
  creates what is missing and reports, without changing, anything that
  exists in another shape.

## Alternatives considered

**Keep the apps in the devbox under a process supervisor.** It would survive
the loss of a pane but not a restart of the devbox, and it ties the apps to
the devbox's lifetime — including its recreation for a new image, which is
exactly when nobody is thinking about them. Separate containers restart on
their own terms.

**Put the apps on `v6net`.** That gives each a global IPv6 address it does not
need, from a `/64` whose addresses are otherwise handed out deliberately, and
makes them reachable around proxyd. A bridge of their own keeps them behind it.

**Publish their ports on the host and forward to the host.** The devbox is not
on the host's network, so proxyd would have to target the bridge gateway, and
the ports would be open on the host for anything else to reach. Container
names on a shared bridge need neither.

**Bake the source into the image, as sd-webui's own Dockerfile does.** Every
edit would need a rebuild, and the venv would be installed a second time into
an image. Mounting what is already there costs nothing and keeps one copy.

**Mount the entrypoints from the dotfiles.** It would save a rebuild when an
entrypoint changes, but the containers would then depend on the checkout they
were started from, and a worktree is deleted once its branch is merged.

**Let compose create the network.** `docker compose down` would then try to
remove it, and the devbox is attached to it. The network belongs to the host,
so `setup-networks` makes it and compose declares it external.

**Start sd-webui through its `webui.sh`.** It adds nothing the arguments need:
the checkout's own are in `webui-user.sh`, which exports `COMMANDLINE_ARGS` and
then runs `webui.sh`, while `webui.sh` itself sources only `webui.settings.sh`.
What it does add is venv handling: it upgrades pip in the venv at every start,
and with no venv it makes one from whatever Python it finds. The entrypoint
runs `launch.py` with the existing venv and fails if there is none.

**A subnet in `10.0.0.0/8`.** It sits outside Docker's default pools, but that
range is what Kubernetes clusters and VPNs tend to use, and this box works with
both. `172.30.0.0/24` is in Docker's pool but far above what it hands out
first, and a subnet in use is skipped by Docker's own allocation anyway.

## Consequences

- A host must have both networks before the devbox is started: the start
  scripts put it on both and `docker run` fails if one is missing. Every host
  gets `sdnet`, including one with no apps, so that there is one layout.
- A devbox created before this joins `sdnet` with `docker network connect`,
  once; the start scripts cover every later one.
- **Whatever is on `sdnet` can reach the apps without going through proxyd**,
  and can set `X-Devbox-User` itself ([[0011]]). That is why the apps are on
  `sdnet` alone rather than on `v6net` with everything else, and why `sdnet`
  holds only the sd containers and the devbox: nothing joins it that is not
  one of them. None of the three apps reads that header; one that starts to
  must not treat it as proof of anything a neighbour could not also claim.
- The containers run whatever is in the checkouts, so a checkout left broken in
  the devbox is a container that keeps restarting. `docker logs` is where that
  shows.
- Setting an app up — making the venv, installing `node_modules` — is still
  done from the devbox. The containers do not install anything on their own.
- The app images have base images of their own, which Renovate tracks the way
  it tracks the devbox's. sd-viewer and tageditor use the same Go and Node the
  devbox does, pinned separately in each file.
- Which apps a host runs is now in two places: its compose file, and the
  `services.<hostname>.yaml` that publishes them. The compose file is what
  runs; `devbox-proxy check` is still what is published.
- The apps' repositories no longer say how to start them; this repository
  does.

## Revision (2026-09-13): hosts whose network is declared with regied

simone's network is now declared with regied, in `net-fraction-private`
(`hosts/simone/`, and its `docs/adr/0003` for the docker side). poissonnerie
has not moved yet. On a host that has:

- The bridge under `v6net` is a regied `Interface` (`br-v6net` on simone). It
  holds the host's container `/64` and sends router advertisements for it.
- The docker network `v6net` is made by `net-fraction-private`'s bootstrap on
  that bridge, with **IPv4 only**: `172.18.<last octet of the host's LAN
  IPv4>.0/24`. Docker knows nothing about the IPv6 prefix.
- Docker turns IPv6 off on the `eth0` of a container on an IPv6-less network. A
  container keeps it only when its own `--network` carries
  `driver-opt=com.docker.network.endpoint.sysctls=net.ipv6.conf.IFNAME.disable_ipv6=0`
  (the network's options do not reach the endpoint), and its address is then
  the RA's prefix with a token set inside the container.
- Docker's `iptables` is turned off in regied's stage 2, so docker masquerades
  no bridge; regied is the only firewall and NAT on the host.

What that changes in the decision above, on such a host:

**`v6net` is not defined in this repository.** "Both networks are defined once
for every host" holds only for hosts whose docker still makes `v6net`.
`devbox/network/` keeps those hosts' files — boucherie's, today — and says so
at the top of its README; it goes when the last of them moves. The devbox's
value on a regied host is the token alone (`::153` for anietta, in
`start-rocm`), which `entrypoint.sh` sets on `eth0` on every start from
`DEVBOX_IP6_TOKEN`. The prefix is written only in `net-fraction-private`.

**There is no `sdnet` on a regied host. The apps join `v6net`, and proxyd
reaches them by container name as before.** Not implemented yet: simone runs no
apps, and poissonnerie keeps `sdnet` until it moves.

- `sdnet` worked because docker masqueraded it. With docker's `iptables` off it
  would have to be a second regied bridge with a `SourceNAT` of its own, a
  segment kept only to separate the apps from their neighbours.
- The reason `v6net` was rejected for the apps above was that they would get a
  global IPv6 address and be reachable around proxyd. On a regied host a
  container has no IPv6 unless its own start line asks for it, and the apps'
  compose files do not. Their IPv4 is routed, not NATed, so it is reachable
  from the home LAN; what keeps them behind proxyd is the host's regied
  firewall, which names containers and ports, rather than a separate segment.
- A second network on the devbox for the apps also stops being needed: the
  devbox, proxyd with it, is already on `v6net`.

### Alternatives considered for the revision

**Fold boucherie's values into `start-cuda` and remove `devbox/network/`
now.** The prefix would move from one file in this repository to another,
still outside `net-fraction-private`, and `setup-networks`, which poissonnerie
still needs for both networks, would have nowhere to read them. Keeping the
directory as it is, marked as covering the hosts that have not moved, changes
nothing for boucherie and is removed in one step when poissonnerie moves.

**Keep `sdnet` on a regied host, declared in regied as a second bridge.** It
restores the separation by segment, at the cost of a second prefix, a second
`SourceNAT` and a second network on the devbox, on every host, for a guarantee
the host firewall already has to give for `v6net`.

**Keep docker's `iptables` on for `sdnet` alone.** It is one switch for the
whole daemon, and turning it off is what makes regied the only firewall on the
host.

### Consequences of the revision

- `start-rocm` joins `v6net` only, with the driver option and the token;
  `start-cuda` is unchanged.
- A compose file for a regied host declares `v6net` as its external network
  instead of `sdnet`, and `test/devbox-apps.bats`, which requires `sdnet`,
  has to learn the difference when the first one is written.
- **Whatever is on `v6net` can reach the apps**, and set `X-Devbox-User`
  itself ([[0011]]). On a regied host that is every container on the bridge,
  not only the sd containers and the devbox. The rule above for an app that
  starts reading the header holds more strongly.
- The host's regied firewall has to leave the apps' ports closed to the LAN
  when it opens the devbox's; that belongs to the firewall stage of that host,
  in `net-fraction-private`.
- The Cloudflare `AAAA` record for the devbox still carries the prefix by hand
  ([[0005]]). Deriving it is outside this revision.

## Revision (2026-09-13): poissonnerie moves as well

poissonnerie's network is now declared with regied too, in
`net-fraction-private` (`hosts/poissonnerie/`), in the same shape as simone's:
`br-v6net` holds the container `/64` and advertises it, and `v6net` is made on
it with IPv4 only (`172.18.151.0/24`). Every devbox host is now a regied host,
so what the revision above left for later is done:

- **`start-cuda` joins `v6net` only**, with the same driver option as
  `start-rocm` and the token `::151`, which `entrypoint.sh` sets on `eth0` as it
  does for anietta.
- **`sdnet` is gone in practice as well as in the decision.** The apps in
  `devbox/apps/compose.boucherie.yaml` declare `v6net` as their external
  network and ask for no IPv6; proxyd and `sdctl` reach them by container name
  as before. `test/devbox-apps.bats` requires `v6net` now, since no host has
  `sdnet`.
- **`devbox/network/` is removed**, with `setup-networks` and
  `test/devbox-network.bats`. No host's docker makes its own `v6net` any more,
  so "both networks are defined once for every host" and the `setup-networks`
  alternatives above describe a layout that no longer exists. No Docker
  network is defined in this repository.

Consequences:

- The devbox's IPv6 address on either host is written in two places: the
  token in the start script, and the prefix in `net-fraction-private`.
- poissonnerie's regied firewall has to keep the apps' ports (7860, 8189, 5173)
  closed to the LAN while it opens the devbox's; that is in
  `net-fraction-private`, not here.
- The apps' images build with `network: host`. The default bridge a build
  uses is in none of regied's zones and reaches nothing outside, the same
  reason `make cuda` and `make rocm` build with `--network host`.
- Recreating boucherie for this change also recreates the app containers, since
  they move from `sdnet` to `v6net`. `sdnet` itself is removed on the host once
  nothing is attached to it.

## Revision (2026-09-19): builds no longer need the host's network

`net-fraction-private`'s ADR 0004 moved docker's default bridge off `docker0`
and onto `br-build`, a bridge regied declares and puts in the `containers`
firewall zone, with jumelle routing the subnet back. A build now reaches the
network from the bridge it would use anyway, and `daemon.json` hands it an
IPv4 resolver, because BuildKit passes the host's own `resolv.conf` to a build
and these hosts resolve over IPv6 only.

So the builds here drop `network: host`, and `make cuda` drops `--network
host`. (`make rocm` never carried the flag: simone's builds went through the
buildx `multiarch` builder, which sits on `v6net`.)

- Verified on both hosts on 2026-09-19: a build installs packages, reaches
  `https://github.com` and resolves a house name, with nothing on the host's
  network namespace.
- The host side of this lives in `net-fraction-private`. What this repository
  may assume is that the default bridge reaches the network and can resolve;
  if a host is not declared with regied, `docker0` is back to being docker's
  own and the flag is not needed there either.
- The buildx builder `multiarch` on simone stays as it is. Nothing here
  depends on where it sits, and a plain `docker build` no longer needs it.
