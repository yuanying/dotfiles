#!/usr/bin/env bash
#
# Starts the llama-server that LLAMA_SERVER names, relative to the working
# directory, which compose sets to the llama.cpp checkout. The arguments are
# llama-server's own, passed by compose. The build is made in the devbox; this
# only runs what is there.

set -euo pipefail

if [[ -z ${LLAMA_SERVER:-} ]]; then
    echo "llama-server: LLAMA_SERVER is not set; compose names the build to run" >&2
    exit 1
fi

if [[ ! -x ${LLAMA_SERVER} ]]; then
    echo "llama-server: no build at ${PWD}/${LLAMA_SERVER}; build it from the devbox first" >&2
    exit 1
fi

exec "${LLAMA_SERVER}" "$@"
