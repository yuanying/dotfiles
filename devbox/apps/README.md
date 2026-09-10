# Apps running next to the devbox

Web apps a host runs permanently, each in a container of its own beside the
devbox rather than in a terminal pane inside it. `compose.<hostname>.yaml`
declares what a host runs; a host without that file runs nothing here. Why it
is done this way is `docs/adr/0012`.

On boucherie:

| Container | Port | Source | After editing the source |
|---|---|---|---|
| `sd-webui` | 7860 | `~/src/github.com/Haoming02/sd-webui-forge-classic` | `docker restart sd-webui` |
| `sd-viewer` | 8189 | `~/src/github.com/yuanying/sd-viewer` | `docker restart sd-viewer` — it is built again at every start |
| `tageditor` | 5173 | `~/src/github.com/iwaco/tageditor` | nothing — uvicorn and vite reload on their own |

The images hold only runtimes and toolchains. The source, the venvs and the
languages they were built with are the ones under `$HOME`, mounted at the same
path as in the devbox, and the containers run as the devbox user (UID 501,
group `staff`). What the apps write belongs to the same user as everything
else, and a checkout edited in the devbox is the one the container runs.

Each container is on `sdnet` only (`devbox/network/README.md`). The devbox is
on it too, so from the devbox the apps are `http://sd-webui:7860`,
`http://sd-viewer:8189` and `http://tageditor:5173`. That is also how proxyd,
which runs in the devbox, forwards to them, and `SDCTL_URL` in
`~/.zshrc.boucherie` points `sdctl` at the first one.

## Before the first start

- `sdnet` exists and the devbox is on it — `devbox/network/README.md`.
- The checkouts are ready to run as they would be in the devbox: the webui has
  its `venv/` (made by running `./webui.sh` from the devbox once), and
  tageditor has `backend/.venv` (`uv sync`) and `frontend/node_modules`
  (`npm install`). The containers only run what is there; they do not set it
  up.
- The NVIDIA container toolkit is installed on the host, as it already is for
  the devbox's `--gpus all`.

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
