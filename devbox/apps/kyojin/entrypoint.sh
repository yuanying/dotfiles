#!/usr/bin/env bash
#
# Starts Kyojin's OpenAI-compatible server, tools/qwen/serve.py, from the
# working directory, which compose sets to the engine checkout. EXL3_VENV is
# the venv to run it with and EXL3_ROCM_SDK the ROCm SDK wheel inside it. The
# arguments are serve.py's own, passed by compose. The extension is built in
# the devbox; this only runs what is there.

set -euo pipefail

for var in EXL3_VENV EXL3_ROCM_SDK; do
    if [[ -z ${!var:-} ]]; then
        echo "kyojin: ${var} is not set; compose names it" >&2
        exit 1
    fi
done

if [[ ! -x ${EXL3_VENV}/bin/python ]]; then
    echo "kyojin: no python at ${EXL3_VENV}/bin/python" >&2
    exit 1
fi

# Without the built extension exllamav3 falls back to compiling it with torch,
# a long and hot build that is not something to start on a restart.
shopt -s nullglob
extension=(exllamav3_ext.*.so)
shopt -u nullglob
if (( ${#extension[@]} == 0 )); then
    echo "kyojin: no built exllamav3_ext in ${PWD}; build it from the devbox first" >&2
    exit 1
fi

# env.sh preloads the SDK's HSA runtime (torch's own segfaults on gfx1151) and
# puts the checkout on PYTHONPATH. Given no argument it sets up for inference;
# without the empty one it would see the server's arguments as its own.
# shellcheck source=/dev/null
source tools/strix_halo/env.sh ''

exec "${EXL3_VENV}/bin/python" tools/qwen/serve.py "$@"
