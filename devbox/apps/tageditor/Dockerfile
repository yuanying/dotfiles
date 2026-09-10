# tageditor, in development mode: uvicorn --reload for the API and the vite
# dev server for the frontend, both reading the checkout compose mounts from
# $HOME. The image is only the two toolchains.

FROM ghcr.io/astral-sh/uv:0.10.6 AS uv

# The Node the devbox has (node_builder in devbox/Dockerfile). The backend's
# Python is not in the image: uv keeps the one its venv uses under $HOME.
FROM node:24.21.0-bookworm-slim

COPY --from=uv /uv /uvx /usr/local/bin/

# The devbox user, so that paths under $HOME resolve and files stay theirs.
# GID 50 is staff, which Debian already has.
RUN useradd -u 501 -g 50 -M -d /home/yuanying -s /bin/bash yuanying
ENV HOME=/home/yuanying \
    USER=yuanying

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

USER 501:50
EXPOSE 5173
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
