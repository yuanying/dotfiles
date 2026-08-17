# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This directory builds a Docker-based personal development environment image. A single `Dockerfile` supports three compute backends (CPU, CUDA, ROCm) via `--build-arg BASE_IMAGE`.

Image registry: `registry.fraction.jp/yuanying/devbox`

It was `yuanying/devbox` until that repository was deprecated in favour of living
here. The move was made because the image and the dotfiles change together — the
container runs `bin/setup.sh` from the parent directory, and the Mac package
script reads the plugin versions pinned below. Paths outside `devbox/` in this
document are relative to the repository root.

## Build Commands

Run from this directory (the build context is `devbox/`, so nothing outside it
reaches the image):

```bash
make image   # CPU variant — $(UBUNTU_IMAGE)
make cuda    # NVIDIA CUDA variant — $(CUDA_IMAGE)
make rocm    # AMD ROCm variant — $(ROCM_IMAGE)
```

Base image tags are defined as `*_IMAGE` variables at the top of the `Makefile`.

## Running Containers

```bash
./start-daemon          # AMD64 CPU container as daemon
./start-cuda            # CUDA GPU container
./start-rocm            # ROCm GPU container
./scripts/run-workspace.sh  # Ephemeral isolated workspace
```

## Dockerfile Architecture

Multi-stage build with these named targets:

| Stage | Role |
|---|---|
| `base` | A toolchain and headers, for what compiles at runtime rather than during this build |
| `user_base` | Everything the user gets from apt, plus locale, sshd and the non-root user `yuanying` (UID 501); can be pushed independently |
| `golang_builder` | Compiles Go toolchain and tools |
| `docker_builder` | Extracts Docker CLI binaries |
| `node_builder` | Supplies the Node.js runtime |
| `herdr_navigator_builder` | Builds the Rust herdr-navigator plugin |
| `herdr_plugin_builder` | Builds herdr plugins into `/opt/herdr/plugins` |
| `main` | Final image combining all stages |

The `make` targets build both `user_base` and `main` in a single `docker build` invocation using multiple `--target` flags.

Where a package goes follows from that table: `base` gets it only if something has to compile
against it, `user_base` gets anything else installable with apt, and `main` is for tools apt does
not carry — toolchains, prebuilt binaries, plugin trees. Note that `user_base` builds on `base`, so
the compiler and headers `base` installs are still there for asdf-built languages and Nvim's
tree-sitter parsers; they are not listed twice. That is the only reason `base` still exists as a
separate stage — no build stage in this file starts from it any more, since the remaining ones
start from their own language images.

`user_base` installs in two apt calls with `etc/apt/apt.conf.d/01norecommend` copied between them.
The first list predates the file and depends on recommends — `less`, `xauth`, `gnupg`, `manpages`
and `ncurses-term` come in that way and nothing names them — while the applications in the second
list never wanted the recommends of podman and virtinst. Moving the copy changes the installed set.

## Key Included Tools

- **Editor**: Neovim (default `vi`/`vim`)
- **Shell**: Zsh with spaceship-prompt, syntax-highlighting, autosuggestions
- **Go**: gopls, goimports, ghq (installed with `@latest`)
- **Terminal**: herdr (prebuilt binary)
- **Diff viewer**: hunk (prebuilt binary, extracted to `/opt/hunk`)
- **Node.js**: system-wide `node` / `npm` / `npx` / `corepack`, from `node_builder`
- **herdr plugins**: herdr-hunk-diff, herdr-navigator (see below)
- **Search**: ripgrep, ag, fd, fzf
- **Navigation**: zoxide (`z`; also feeds herdr-navigator's zoxide source)
- **K8s**: kubectx, kubens
- **Version manager**: asdf

Pinned versions live in `ARG <NAME>_VERSION` declarations in the `Dockerfile`; do not hardcode
them anywhere else. That holds across the whole repository, not just this directory —
`bin/mac/setup-packages.sh` reads the ARGs it needs out of this file rather than repeating them.

## Herdr Plugins

Plugins are built in `herdr_plugin_builder`, one block per plugin, into
`/opt/herdr/plugins/<plugin id>` — the id being the `id` field of the plugin's `herdr-plugin.toml`.
The main stage copies that directory as a whole, and `entrypoint.sh` links every plugin it finds
there. herdr registers plugins under `~/.config/herdr`, which the host `$HOME` mount hides, which is
why linking happens at runtime rather than at build time.

To add a plugin, pin its version with a Renovate-annotated `ARG <NAME>_VERSION`, clone it at that
tag into `/opt/herdr/plugins/<plugin id>`, and run the build commands its manifest declares.
Nothing outside that block needs to change.

Three things to keep in mind:

- `herdr plugin link` does not run a plugin's build commands, so the tree in the image has to be
  built already. Plugin config and state live under `$HOME`, so the tree itself stays read-only.
- Plugins may vendor large binaries that this image already ships. herdr-hunk-diff, for instance,
  depends on the `hunkdiff` npm package (~500 MB, it bundles Bun) purely to obtain a hunk binary;
  it is dropped after the build and the path the plugin resolves points at `/opt/hunk` instead.
- `herdr_plugin_builder` is a Node stage because plugin manifests usually declare npm builds. A
  plugin on another toolchain gets its own stage and is copied in at the end of
  `herdr_plugin_builder`, so the main stage keeps copying `/opt/herdr/plugins` as one directory.
  herdr-navigator works this way: `herdr_navigator_builder` runs `cargo build --release`, then
  strips everything from `target/` except the binary the manifest invokes.

Keybindings are not part of the image. They live in `herdr/config*.toml`, which is per host and
has no include mechanism, so a binding has to be added to every one of those files.
herdr-navigator is bound to `prefix+t`; `prefix+a` opens it filtered to Agents.

Macs have no image to link from, so `bin/mac/setup-packages.sh` installs the same plugins from
GitHub. It does not repeat the versions: it seds the `ARG <NAME>_VERSION` it wants out of this
`Dockerfile` and passes it as `--ref v<version>`, so a Renovate bump here reaches the Mac on the
next run. Adding a plugin that a Mac should get too means adding a call there naming the new ARG.

herdr-hunk-diff is the one plugin not taken from its original author. It comes from
`yuanying/herdr-hunk-diff`, a fork adding `review.branch_scope` so a branch review can include
uncommitted and untracked files. Two things differ from the rule above: its tags are
`v<upstream>-fork.<N>` and therefore carry a `versioning=regex` in the annotation, and its install
directory keeps the upstream vendor prefix because that string is the plugin id — `entrypoint.sh`
links by it and the dotfiles keybindings name it. The fork releases itself when upstream does; this
repository is where that lands as a Renovate PR. To go back to upstream, restore the plain
annotation and clone URL and set the ARG to an upstream version — Renovate cannot make that hop
because the versioning scheme changes. The fork's FORK.md has the details.

## Dependency Updates (Renovate)

Renovate keeps the pinned versions up to date. Configuration is in `renovate.json` at the
repository root, because that is the only place Renovate reads it from:

- Base images in `FROM` / `ARG BASE_IMAGE` are picked up by the built-in `dockerfile` manager.
- `ARG <NAME>_VERSION=` in the `Dockerfile` and `<NAME>_IMAGE :=` in the `Makefile` are picked up by
  custom regex managers, driven by a preceding `# renovate: datasource=... depName=...` comment.
  Their `managerFilePatterns` name these two files by their `devbox/` paths, so a file moved out of
  this directory stops being tracked.
- Ubuntu is intentionally held at 24.04 (disabled by a package rule).

When adding a new pinned tool, follow the same annotation + `ARG` naming convention so Renovate
picks it up automatically. Validate changes from the repository root with:

```bash
npx --package renovate renovate-config-validator
npx --package renovate renovate --platform=local --dry-run=extract
```

The second command should report fifteen dependencies across `devbox/Dockerfile` and
`devbox/Makefile`; a manager whose pattern stopped matching shows up as a missing file there.

## Container Runtime Notes

- Runs privileged with `SYS_PTRACE` capability
- Mounts host `$HOME` for persistence
- Mounts Docker socket for nested container access
- SSH daemon on port 3222; also exposes 8080, 9090, 60000–60010 UDP (mosh)
- `entrypoint.sh` hands a small set of variables to sshd via `SetEnv`, because `sudo` strips the
  image `ENV` and OpenSSH rebuilds the session environment. Processes that never go through a
  login shell — herdr, exec'd straight from mosh, and the hunk binary and Nvim it spawns — read
  these directly, so the dotfiles `zshrc` cannot supply them. Values live in exactly one place:
  `EDITOR` / `VISUAL` in the `Dockerfile`, and everything host-specific in the dotfiles' own
  `~/.zshrc.<hostname>`. Whatever that file exports is forwarded automatically — it is diffed
  against a pristine zsh, so adding a variable needs no image rebuild. Two things follow from
  that: sshd's arguments show up in `ps`, so anything that file exports becomes world-readable
  and secrets belong in `~/.zsh_private` instead; and a value containing whitespace is skipped,
  since `SetEnv` cannot represent it. `-o SetEnv` also honours only its first occurrence, which
  is why every variable goes into a single `-o`.
- On first start, `entrypoint.sh` fetches SSH keys from GitHub, installs zsh plugins, and clones
  the dotfiles into `~/dotfiles`. That is this same repository, cloned from GitHub rather than
  copied out of the build context on purpose: the container's `$HOME` is the host's, so the working
  copy has to be the host's too, not a snapshot frozen at image build time.
