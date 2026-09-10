# 0012. Run the sd apps in containers on a bridge of their own

- Date: 2026-09-10
- Status: Accepted

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

**Start sd-webui through its `webui.sh`.** The script sources `webui-user.sh`,
whose `COMMANDLINE_ARGS` would override what the container passes, and with no
venv it makes one from whatever Python it finds. The entrypoint runs
`launch.py` with the existing venv and fails if there is none.

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
