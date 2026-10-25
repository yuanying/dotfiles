# Apps running next to the devbox

Web apps a host runs permanently, each in a container of its own beside the
devbox rather than in a terminal pane inside it. `compose.<hostname>.yaml`
declares what a host runs; a host without that file runs nothing here. Why it
is done this way is `docs/adr/0012`.

On boucherie:

| Container | Port | Source | After editing the source |
|---|---|---|---|
| `sd-webui` | 7860 | `~/src/github.com/yuanying/sd-webui-forge-neo` | `docker restart sd-webui` |
| `sd-viewer` | 8189 | `~/src/github.com/yuanying/sd-viewer` | `docker restart sd-viewer` — it is built again at every start |
| `tageditor` | 5173 | `~/src/github.com/iwaco/tageditor` | nothing — uvicorn and vite reload on their own |
| `lora-compare` | 8080 | `~/src/github.com/kohya-ss/sd-scripts/outputs/images` | nothing — nginx serves the files as they are |
| `lora-datasets` | 8765 | `~/src/github.com/yuanying/lora_datasets` | `docker restart lora-datasets` |

On anietta:

| Container | Port | Source | After editing the source |
|---|---|---|---|
| `llama-server` | 8082 | `~/src/github.com/Niko1221/Strata` (Strata, with its `.venv` and `~/opt/strata-rocm`) | `docker restart llama-server` after a rebuild |

It serves Qwen3.8-Flash-Next as `qwen3.8-flash-next` with Strata
(`github.com/Niko1221/Strata`, v0.2.4), from the abliterated IQ4_XS GGUF
llama.cpp served (`~/models/qwen3.8-flash-next/Qwen3.8-Flash-Next-Uncensored.i1-IQ4_XS.gguf`,
mradermacher's i1 quant of `orcarouter/Qwen3.8-Flash-Next-Uncensored`) and a
pack made from it in `~/models/strata-packs/orca-mradermacher-i1-iq4_xs`, with
the original model's MTP head in `~/models/strata-mtp/rt`. The engine is built
in the devbox for gfx1151 against AMD's TheRock ROCm 7.14.1 in
`~/opt/strata-rocm/install`, which the entrypoint puts ahead of the image's;
the image is the ROCm base Kyojin's used. How it was built, packed and
measured is in [llama-server/STRATA.md](llama-server/STRATA.md). Where it is
published is not in this repository: the `qwen38` entry in
`~/.config/devbox-proxy/services.local.yaml` (`docs/adr/0009`) forwards to
`llama-server:8082`. The container keeps the name it had when it ran
llama.cpp, so that entry and the clients did not change.

The settings are the ones measured in STRATA.md: 256K of context with an int8
KV cache, every expert (61 GiB) in the GPU's cache and read from the GGUF
through the file cache, 16,384-token prompt chunks, MTP and lookup drafting,
and docs/STRIX_HALO.md's fast switches, several of which round differently
from the engine's default path. Thinking is on unless a request turns it off
with `chat_template_kwargs.enable_thinking: false` or `reasoning_effort:
"none"`. Pictures go through the CPU reader.

**The CPU is capped.** It was measured, and runs, with every CPU's maximum
frequency lowered to 3 GHz (a sysfs write, not persisted: a reboot lifts it,
and `restart: always` then starts Strata uncapped). With a partial expert
cache and no cap its CPU pool drove the CPU to 98 °C within minutes. The cap
and its snapshot are kept outside this repository; restoring it is
`evox2-cpu-limit.py restore --snapshot <snapshot> --confirm-host-change`.

It is not llama.cpp's server, and clients written for that one may miss:

- `logprobs` is ignored.
- `response_format` with a JSON schema is checked only as one JSON object
  (the `jsonschema` package is not in the venv).
- `/health` answers `ok` before the model is up; `loaded: true` says it is.

What it does have: `/v1/models`, `/v1/chat/completions` (streaming with
usage, tools with `tool_choice` auto, `required`, named or `none`, images),
`/v1/messages`, `/v1/responses`, `/props` and `/slots`.

A start takes under a minute when the GGUF is in the page cache, most of it
filling the expert cache (`pre-filled 24576 of 24576 slots` in
`~/.cache/strata/engine.log`).

Before Strata it served Kyojin: the decensored `trohrbaugh/Qwen3.8-Flash-Next-heretic-2`
converted here to EXL3 (`f396390`, pack since deleted), and for a while the
abliterated `Lygodactylus/Qwen3.8-Flash-Next-Uncensored-exl3-4bpw` (`f0cc086`,
deleted too). Kyojin's image is still `kyojin/`, built as
`devbox-apps-kyojin`, and its checkout is in `~/opt/kyojin`; how those packs
were fetched, converted and tried is in
[llama-server/KYOJIN-INFER.md](llama-server/KYOJIN-INFER.md).

### Going back to the Yamz pack

Kyojin also served `yamz-labs/Qwen3.8-Flash-Next-EXL3-Yamz`
(revision `247ef39b`) with that pack's runtime uncensor preset, and the pack
is still in `~/models/qwen3.8-flash-next-exl3-yamz-247ef39b`. Its compose
definition is the one in `ef00aa7`; to run it again without touching the
checkout:

```bash
git -C ~/dotfiles show ef00aa7:devbox/apps/compose.anietta.yaml |
    docker compose -f - --project-directory ~/dotfiles/devbox/apps up -d --no-build llama-server
```

Kyojin's image is still there, so nothing is built. Restore the CPU's
maximum frequency as well (above) if Strata is not coming back. To keep it,
revert this change through a pull request.

### Going back to llama.cpp

The llama.cpp setup is kept: its image is still `llama-server/`, built as
`devbox-apps-llama-server` (Kyojin's is `devbox-apps-kyojin`), and its models
in `~/models/qwen3.8-flash-next*` and its build in
`~/src/github.com/halo-box/strix-prefill-opt` are where they were. Its compose
definition is the one in `4562c2f`, the commit before Kyojin. To run it
again without touching the checkout:

```bash
git -C ~/dotfiles show 4562c2f:devbox/apps/compose.anietta.yaml |
    docker compose -f - --project-directory ~/dotfiles/devbox/apps up -d --no-build llama-server
```

`--no-build` starts the image that is already there, so going back does not
depend on reaching Docker Hub for the base; if that image is gone, the same
command with `--build` makes it again. That replaces the container; `qwen38` and the clients see the same name and
port. To keep it that way, revert the change that brought Kyojin in, through
a pull request as usual, and run the usual `up -d --build` once it is merged:
until then, the next `up -d --build` from `~/dotfiles` brings Kyojin back.

The images hold only runtimes and toolchains. The source, the venvs and the
languages they were built with are the ones under `$HOME`, mounted at the same
path as in the devbox, and the containers run as the devbox user (UID 501,
group `staff`). What the apps write belongs to the same user as everything
else, and a checkout edited in the devbox is the one the container runs.

Each container is on `v6net` only, with IPv4 alone: `v6net` is the host's
regied bridge, which `net-fraction-private` declares and creates, and nothing
in the compose file keeps IPv6 on for the apps (`docs/adr/0012`). The host's
regied firewall keeps their ports closed to the LAN. The devbox is on `v6net`
too, so from the devbox the apps are `http://sd-webui:7860`,
`http://sd-viewer:8189` and `http://tageditor:5173`. That is also how proxyd,
which runs in the devbox, forwards to them, and `SDCTL_URL` in
`~/.zshrc.boucherie` points `sdctl` at the first one.

## Before the first start

- `v6net` exists and the devbox is on it — `net-fraction-private` makes the
  network, and `devbox/start-cuda` puts the devbox on it.
- The checkouts are ready to run as they would be in the devbox: the webui has
  its `venv/` (made by running `./webui-user.sh` from the devbox once and
  stopping it when it is up; `./webui.sh` alone misses the `COMMANDLINE_ARGS`
  that `webui-user.sh` exports, `--uv` among them), and
  tageditor has `backend/.venv` (`uv sync`) and `frontend/node_modules`
  (`npm install`), and lora_datasets has its `.venv` (`uv sync`). The
  containers only run what is there; they do not set it up.
- The NVIDIA container toolkit is installed on the host, as it already is for
  the devbox's `--gpus all`.
- On anietta, Kyojin is in `~/opt/kyojin` (the checkout with its extension
  built, and the venv) and the pack in
  `~/models/qwen3.8-flash-next-exl3-heretic2-4bpw-207cd22c`, and
  `~/.cache/kyojin/slots` exists for `--slot-save-path`, which does not make
  it.

## Operating

Run these from the devbox, which drives the host's Docker through the mounted
socket, or on the host itself. The compose file is found by host name:

```bash
docker compose -f ~/dotfiles/devbox/apps/compose.$(hostname -s).yaml up -d --build
```

That builds the images and starts whatever is not running, and it is also how
a change to a `Dockerfile` or to the compose file takes effect. The project
name is fixed in the file, so it does not matter which checkout the command is
run from: a worktree used to try a change and `~/dotfiles` manage the same
containers. The checkout is read only while building; nothing a container runs
comes from it afterwards.

The builds run on the default bridge, with nothing special in the compose
file. On a regied host that bridge is `br-build`, which the declaration puts in
a firewall zone and jumelle routes back, so a build reaches the network and can
resolve names (`net-fraction-private`'s ADR 0004). Before that it was `docker0`,
which reached nothing outside, and the builds here carried `network: host`.

| To | Run |
|---|---|
| see what is running | `docker compose -f … ps` |
| follow a log | `docker logs -f sd-webui` |
| restart one | `docker restart sd-viewer` |
| stop them all and remove the containers | `docker compose -f … down` |

`restart: always` brings every container back after it exits, after a Docker
restart and after a reboot. Only `down` (or `docker stop`) keeps one down.
The sd-webui "Restart" button exits the process, and the container restart
policy is what starts it again.

tageditor runs two processes, the API and the vite dev server. If either one
exits, the container exits with it and is restarted whole. A change to its
dependencies is installed from the devbox as usual (`uv add` / `npm install`)
and followed by `docker restart tageditor`.

## What is not in the checkouts any more

The arguments sd-webui starts with are in the compose file, not in the
checkout's `webui-user.sh`, which the container does not read. It listens on
every interface of its container with `--listen`; the `--server-name` that
made it reachable from outside the devbox has no purpose in a container.

sd-viewer reads the same `~/.config/sd-viewer/config.toml` as before. The
compose file overrides only the WebUI address, which inside the container is
the `sd-webui` container rather than `localhost`.

tageditor is given `TAGEDITOR_ALLOWED_HOSTS` so that vite accepts requests
addressed to its public name, which proxyd passes through unchanged.
