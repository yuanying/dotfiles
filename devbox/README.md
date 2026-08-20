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
`https://<name>.oeilvert.org` behind a Cloudflare Access login, driven by one
declaration file per host. `entrypoint.sh` starts it on boot and skips it
silently when no origin certificate is present, so it is not something the
container depends on. See `proxy/README.md`, and `docs/adr/0001` to `0004` for
why it is built the way it is.

## License

MIT — the rest of the dotfiles repository is Apache-2.0, so this directory
keeps its own `LICENSE`.
