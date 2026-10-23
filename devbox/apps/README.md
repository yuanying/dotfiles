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
| `llama-server` | 8082 | `~/opt/kyojin/src` (Kyojin, with `~/opt/kyojin/venv`) | `docker restart llama-server` after a rebuild |

It serves Qwen3.8-Flash-Next as `qwen3.8-flash-next`, from the EXL3 pack in
`~/models/qwen3.8-flash-next-exl3-yamz-247ef39b`
(`yamz-labs/Qwen3.8-Flash-Next-EXL3-Yamz`, revision `247ef39b`), with Kyojin
(`github.com/Yamz-Labs/kyojin`), Yamz Labs' engine built on ExLlamaV3 for
Strix Halo. The checkout is at `e09322da`;
its extension (`exllamav3_ext.*.so`) is built in the devbox, and the venv
holds the ROCm torch and SDK wheels it was built against. The image is the
ROCm base the devbox is built on; the devices are `/dev/kfd` and `/dev/dri`,
with simone's `video` and `render` GIDs. Where it is published is not in this
repository: the `qwen38` entry in `~/.config/devbox-proxy/services.local.yaml`
(`docs/adr/0009`) forwards to `llama-server:8082`. The container keeps the
name it had when it ran llama.cpp, so that entry and the clients did not
change.

The settings are the ones it was measured with: 256K of context in one pool
of KV pages that two sessions share, an fp16 cache, MTP and n-gram drafting,
the pack's uncensor preset (a projection applied as the model runs, not the
abliterated IQ4_XS llama.cpp served), and the n-gram embedding table read
from its file rather than held in RAM. Thinking is on unless a request turns
it off with `chat_template_kwargs.enable_thinking: false` (or
`reasoning_effort: "none"`), at the template's default effort, `xhigh`. A
request without `max_tokens` or `max_completion_tokens` may answer until the
context is full.

It is not llama.cpp's server, and clients written for that one may miss:

- `tool_choice` is ignored: the model decides whether to call a tool, and a
  forced or named choice is not enforced. `response_format` is ignored too.
- There is no `/v1/embeddings`, `/props`, `/metrics` or `/v1/messages`.
- The llama.cpp-style `/completion` answers 128 tokens when not given
  `n_predict`.
- `cache_prompt: false` is refused while there is more than one session.

What it does have: `/health` (503 with the load progress until it is ready),
`/v1/models`, `/v1/chat/completions` (streaming, tools, images,
`logprobs` with up to 20 `top_logprobs`), `/v1/completions`, `/completion`,
`/tokenize`, `/apply-template` and `/slots`.

A start takes about a minute when the weights are in the page cache, most
of it reading them, and longer from a cold disk. When it is up, `docker logs llama-server` shows the preset as
`ablit runtime: spec …/uncensor_spec.json active` and the table as
`[ngram] table mode trellis_disk`.

For a while it served an abliterated EXL3 pack instead
(`Lygodactylus/Qwen3.8-Flash-Next-Uncensored-exl3-4bpw`, revision
`9c715c0b`, with `EXL3_ABLIT_RUNTIME=off`; `f0cc086`). That pack has been
deleted from `~/models`, so its compose definition no longer runs. The
scripts that fetched and tried it, and its manifest, are in
[llama-server/KYOJIN-INFER.md](llama-server/KYOJIN-INFER.md).

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
  `~/models/qwen3.8-flash-next-exl3-yamz-247ef39b`, and
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
