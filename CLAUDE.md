# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository builds a Docker-based personal development environment image. A single `Dockerfile` supports three compute backends (CPU, CUDA, ROCm) via `--build-arg BASE_IMAGE`.

Image registry: `registry.fraction.jp/yuanying/devbox`

## Build Commands

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
| `base` | System packages, non-root user `yuanying` (UID 501) |
| `user_base` | User-level environment (can be pushed independently) |
| `golang_builder` | Compiles Go toolchain and tools |
| `docker_builder` | Extracts Docker CLI binaries |
| `tmux_builder` | Builds Tmux from source |
| `node_builder` | Supplies the Node.js runtime |
| `herdr_plugin_builder` | Builds herdr plugins into `/opt/herdr/plugins` |
| `main` | Final image combining all stages |

The `make` targets build both `user_base` and `main` in a single `docker build` invocation using multiple `--target` flags.

## Key Included Tools

- **Editor**: Neovim (default `vi`/`vim`)
- **Shell**: Zsh with spaceship-prompt, syntax-highlighting, autosuggestions
- **Go**: gopls, goimports, ghq (installed with `@latest`)
- **Terminal**: Tmux (built from source), herdr (prebuilt binary)
- **Diff viewer**: hunk (prebuilt binary, extracted to `/opt/hunk`)
- **Node.js**: system-wide `node` / `npm` / `npx` / `corepack`, from `node_builder`
- **herdr plugins**: herdr-hunk-diff (see below)
- **Search**: ripgrep, ag, fd, fzf
- **K8s**: kubectx, kubens
- **Version manager**: asdf

Pinned versions live in `ARG <NAME>_VERSION` declarations in the `Dockerfile`; do not hardcode
them anywhere else.

## Herdr Plugins

Plugins are built in `herdr_plugin_builder`, one block per plugin, into
`/opt/herdr/plugins/<plugin id>` — the id being the `id` field of the plugin's `herdr-plugin.toml`.
The main stage copies that directory as a whole, and `entrypoint.sh` links every plugin it finds
there. herdr registers plugins under `~/.config/herdr`, which the host `$HOME` mount hides, which is
why linking happens at runtime rather than at build time.

To add a plugin, pin its version with a Renovate-annotated `ARG <NAME>_VERSION`, clone it at that
tag into `/opt/herdr/plugins/<plugin id>`, and run the build commands its manifest declares.
Nothing outside that block needs to change.

Two things to keep in mind:

- `herdr plugin link` does not run a plugin's build commands, so the tree in the image has to be
  built already. Plugin config and state live under `$HOME`, so the tree itself stays read-only.
- Plugins may vendor large binaries that this image already ships. herdr-hunk-diff, for instance,
  depends on the `hunkdiff` npm package (~500 MB, it bundles Bun) purely to obtain a hunk binary;
  it is dropped after the build and the path the plugin resolves points at `/opt/hunk` instead.

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

Renovate keeps the pinned versions up to date. Configuration is in `renovate.json`:

- Base images in `FROM` / `ARG BASE_IMAGE` are picked up by the built-in `dockerfile` manager.
- `ARG <NAME>_VERSION=` in the `Dockerfile` and `<NAME>_IMAGE :=` in the `Makefile` are picked up by
  custom regex managers, driven by a preceding `# renovate: datasource=... depName=...` comment.
- Ubuntu is intentionally held at 24.04 (disabled by a package rule).

When adding a new pinned tool, follow the same annotation + `ARG` naming convention so Renovate
picks it up automatically. Validate changes with:

```bash
npx --package renovate renovate-config-validator
npx --package renovate renovate --platform=local --dry-run=extract
```

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
- On first start, `entrypoint.sh` fetches SSH keys from GitHub, installs zsh plugins, and clones dotfiles
