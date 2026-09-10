# sd-viewer. The image is only the Go toolchain: the entrypoint builds the
# checkout compose mounts from $HOME every time the container starts, so
# `docker restart sd-viewer` is how an edit is picked up.

# The same toolchain the devbox has (golang_builder in devbox/Dockerfile).
FROM golang:1.27

# The devbox user, so that paths under $HOME resolve and files stay theirs.
# GID 50 is staff, which Debian already has.
RUN useradd -u 501 -g 50 -M -d /home/yuanying -s /bin/bash yuanying

# GOPATH as the devbox's zshrc sets it, so the module and build caches under
# $HOME are shared rather than downloaded again into the container.
ENV HOME=/home/yuanying \
    USER=yuanying \
    GOPATH=/home/yuanying

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

USER 501:50
EXPOSE 8189
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
