# A Docker image for my development environment

This used to be `yuanying/devbox`, a repository of its own. It lives here now
because every change to it needed a matching change to the dotfiles anyway —
`entrypoint.sh` clones this same repository into the container and runs
`bin/setup.sh`, and the herdr plugin versions pinned in the `Dockerfile` are
what `bin/mac/setup-packages.sh` installs on a Mac.

```
$ git clone https://github.com/yuanying/dotfiles && cd dotfiles/devbox
$ make image        # CPU; `make cuda` and `make rocm` for the GPU variants
$ ./start-daemon
```

The build context is this directory, so nothing outside it goes into the image.

## Publishing HTTP servers

`proxy/` puts an HTTP server running in the container on
`https://<name>.<zone>` behind a GitHub login, driven by one declaration file
per host — anietta publishes into `oeilvert.dev`, boucherie into
`poissonnerie.dev`. One process handles TLS, the login and the proxying;
certificates come from Let's Encrypt and renew themselves, and the only thing
outside the devbox is a wildcard DNS record. `entrypoint.sh` starts it on boot
and skips it silently when the host declares nothing, so it is not something
the container depends on. See `proxy/README.md`, and `docs/adr/0004` to `0008`
for why it is built the way it is.

## SSH agent

The container has no systemd, so nothing starts an ssh-agent for you.
`zsh.d/12_ssh_agent.zsh` does: on Linux, a shell that cannot reach an agent
uses the one at `~/.ssh/agent/agent.sock`, starting it if it is not running.
Every shell shares that one agent, and it outlives the shell that started it.
An agent that is already reachable — one forwarded from a Mac with `ssh -A` —
is left in place.

`sshconfig` sets `AddKeysToAgent yes` for `github.com` only, so the first
`git fetch` puts the key GitHub accepted — one of the default `~/.ssh/id_*` —
into the agent, and that is the only key a host you forward the agent to can
use.

- To use GitHub from a host you log in to, such as a Pod: `ssh -A <host>`.
- If the key is not loaded yet: `ssh -T git@github.com`, which loads only that
  key. `ssh-add` with no arguments works too, but loads every default key.
- To see what the agent holds: `ssh-add -l`.

## License

MIT — the rest of the dotfiles repository is Apache-2.0, so this directory
keeps its own `LICENSE`.
