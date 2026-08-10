# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository builds a Docker-based personal development environment image. A single `Dockerfile` supports three compute backends (CPU, CUDA, ROCm) via `--build-arg BASE_IMAGE`.

Image registry: `registry.fraction.jp/yuanying/devbox`

## Build Commands

```bash
make image   # CPU variant — ubuntu:24.04
make cuda    # NVIDIA CUDA variant — nvidia/cuda:13.1.0-devel-ubuntu24.04
make rocm    # AMD ROCm variant — rocm/dev-ubuntu-24.04:7.2.2-complete
```

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
| `tmux_builder` | Builds Tmux 3.5a from source |
| `main` | Final image combining all stages |

The `make` targets build both `user_base` and `main` in a single `docker build` invocation using multiple `--target` flags.

## Key Included Tools

- **Editor**: Neovim 0.11.1 (default `vi`/`vim`)
- **Shell**: Zsh with spaceship-prompt, syntax-highlighting, autosuggestions
- **Go**: 1.25 with gopls, goimports, ghq
- **Terminal**: Tmux 3.5a (built from source), herdr 0.8.0 (prebuilt binary)
- **Diff viewer**: hunk 0.18.0 (prebuilt binary, extracted to `/opt/hunk`)
- **Search**: ripgrep, ag, fd, fzf
- **K8s**: kubectx, kubens
- **Version manager**: asdf

## Container Runtime Notes

- Runs privileged with `SYS_PTRACE` capability
- Mounts host `$HOME` for persistence
- Mounts Docker socket for nested container access
- SSH daemon on port 3222; also exposes 8080, 9090, 60000–60010 UDP (mosh)
- On first start, `entrypoint.sh` fetches SSH keys from GitHub, installs zsh plugins, and clones dotfiles
