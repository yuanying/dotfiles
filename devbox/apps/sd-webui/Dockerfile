# sd-webui (Forge Neo). The image is only a runtime: the source, its venv and
# the Python the venv was made from are all under $HOME, which compose mounts
# at the same path, so an edit in the devbox is one restart away.

FROM ghcr.io/astral-sh/uv:0.12.13 AS uv

# The venv's Python is built by asdf inside the devbox, which is Ubuntu 24.04,
# so this has to be 24.04 too for the glibc and libraries it was linked with.
# torch brings its own CUDA libraries in the venv; the base supplies the rest
# of what the NVIDIA runtime expects.
FROM nvidia/cuda:13.1.0-runtime-ubuntu24.04

# The first line is what the asdf-built Python links against, the second what
# opencv, torch and the webui itself load, git included for its version check.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libbz2-1.0 libffi8 libgdbm6t64 liblzma5 libncursesw6 libreadline8t64 libsqlite3-0 libssl3t64 libuuid1 zlib1g \
        ca-certificates git libgl1 libglib2.0-0t64 libgomp1 libtcmalloc-minimal4t64 \
    && rm -rf /var/lib/apt/lists/*

# --uv makes the webui install packages with uv.
COPY --from=uv /uv /uvx /usr/local/bin/

# The devbox user, so that paths under $HOME resolve and files stay theirs.
# GID 50 is staff, which Ubuntu already has.
RUN useradd -u 501 -g 50 -M -d /home/yuanying -s /bin/bash yuanying
ENV HOME=/home/yuanying \
    USER=yuanying

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

USER 501:50
EXPOSE 7860
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
