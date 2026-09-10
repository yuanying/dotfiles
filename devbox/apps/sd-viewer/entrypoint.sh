#!/usr/bin/env bash
#
# Builds the sd-viewer checkout in the working directory and runs the result
# with the arguments compose passes. The binary goes to the container's own
# temporary directory, not into the checkout the devbox also builds in.

set -euo pipefail

bin=${TMPDIR:-/tmp}/sd-viewer
go build -o "${bin}" ./cmd/sd-viewer
exec "${bin}" "$@"
