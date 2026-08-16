#!/bin/bash

# This script creates a new workspace for ephemeral development environments.
# And run docker container for development use.
#
# It creates a directory `~/workspaces/<workspace-name>` and copies essential files from home directory to the new workspace.
#
# Esential files to copy:
# - .ssh/
# - dotfiles/
#
# Usage: ./run-workspace.sh <ipv6-segment>

set -e

IPV6_SEGMENT=${1:-10}
DEV_BOX_TAG=${DEV_BOX_TAG:-"rocm"}

IPv6_ADDRESS="${IPV6_DEV_NETWORK}${IPV6_SEGMENT}"
WORKSPACE_NAME="$(hostname)-${IPV6_SEGMENT}"
WORKSPACE_DIR="$HOME/workspaces/$WORKSPACE_NAME"

ESSENTIAL_FILES=(".ssh" ".zsh" "dotfiles")
COPY_IF_NOT_EXIST=(".asdf" ".tool-versions")

# Create the workspace directory
mkdir -p "$WORKSPACE_DIR"
echo "Created workspace directory: $WORKSPACE_DIR"

# Copy essential files to the new workspace
# Using rsync to preserve file attributes and handle directories
for FILE in "${ESSENTIAL_FILES[@]}"; do
    if [ -e "$HOME/$FILE" ]; then
        rsync -a "$HOME/$FILE" "$WORKSPACE_DIR/"
        echo "Copied $FILE to $WORKSPACE_DIR/"
    else
        echo "Warning: $FILE does not exist in home directory."
    fi
done

for FILE in "${COPY_IF_NOT_EXIST[@]}"; do
    echo "Checking $FILE..."
    if [ ! -e "$WORKSPACE_DIR/$FILE" ]; then
        rsync -a "$HOME/$FILE" "$WORKSPACE_DIR/"
        echo "Copied $FILE to $WORKSPACE_DIR/"
    fi
done

ROOT=$(dirname "${BASH_SOURCE}")

if docker ps -a --format '{{.Names}}' | grep -Eq "^${WORKSPACE_NAME}\$"; then
    echo "Container $WORKSPACE_NAME already exists. Starting it if not running..."
    docker start $WORKSPACE_NAME
    exit 0
fi

ENV_FLAG=""
if [[ ${DEV_BOX_TAG} == "cuda" ]]; then
    ENV_FLAG="--gpus all"
fi

exec docker run \
    -d \
    --name $WORKSPACE_NAME \
    --hostname $WORKSPACE_NAME \
    --privileged \
    --cap-add=SYS_PTRACE \
    --security-opt seccomp=unconfined \
    --group-add video \
    --group-add render \
    ${ENV_FLAG} \
    --ipc=host \
    --restart always \
    -it \
    --network v6net --ip6 $IPv6_ADDRESS \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /lib/modules:/lib/modules \
    -v /dev:/dev \
    -v /usr/share/ca-certificates:/usr/share/ca-certificates \
    -v /etc/ssl/certs:/etc/ssl/certs \
    --mount type=bind,source=${WORKSPACE_DIR},target=/home/yuanying,bind-propagation=slave \
    -w /home/yuanying \
    --add-host braque:192.168.1.131 \
    --add-host chirico:192.168.1.83 \
    --add-host ducump:192.168.1.135 \
    --add-host pablo:192.168.1.134 \
    --add-host pablo:192.168.1.134 \
    --add-host poissonnerie:192.168.1.151 \
    --add-host uribo:192.168.1.152 \
    --add-host simone:192.168.1.153 \
    registry.fraction.jp/yuanying/devbox-${DEV_BOX_TAG}
