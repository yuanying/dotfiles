# lora-datasets: the UI that picks LoRA training images out of the
# lora_datasets repository and generates sd-scripts settings. It runs the
# checkout compose mounts from $HOME with the venv uv made there; the image is
# only uv and git, which the app calls to read the repository.

FROM ghcr.io/astral-sh/uv:0.13.5 AS uv

# The venv's Python is not in the image: uv keeps it under $HOME.
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /uvx /usr/local/bin/

# The devbox user, so that paths under $HOME resolve and files stay theirs.
# GID 50 is staff, which Debian already has.
RUN useradd -u 501 -g 50 -M -d /home/yuanying -s /bin/bash yuanying
ENV HOME=/home/yuanying \
    USER=yuanying

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

USER 501:50
EXPOSE 8765
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
