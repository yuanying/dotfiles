#!/usr/bin/env bash
#
# Starts Strata's OpenAI-compatible server (serve.server) on 0.0.0.0:8082.
# STRATA_ROOT is the checkout (build-halo/strata, build-vision, .venv) and
# STRATA_SDK the ROCm it was built with; the arguments are the engine's own,
# passed by compose. The server reads a run config, written here from them.

set -euo pipefail

for var in STRATA_ROOT STRATA_SDK STRATA_TOKENIZER STRATA_MODEL_NAME STRATA_LOG; do
    if [[ -z ${!var:-} ]]; then
        echo "strata: ${var} is not set; compose names it" >&2
        exit 1
    fi
done

for file in "${STRATA_ROOT}/build-halo/strata" "${STRATA_ROOT}/.venv/bin/python"; do
    if [[ ! -x ${file} ]]; then
        echo "strata: no ${file}; build it from the devbox first" >&2
        exit 1
    fi
done

# The ROCm the engine was built with, ahead of the image's own.
export ROCM_PATH=${STRATA_SDK} HIP_PATH=${STRATA_SDK} HIP_PLATFORM=amd
export LD_LIBRARY_PATH=${STRATA_SDK}/lib:${STRATA_SDK}/lib/rocm_sysdeps/lib:${STRATA_SDK}/lib/llvm/lib
export PATH=${STRATA_ROOT}/.venv/bin:${STRATA_SDK}/bin:${PATH}

config=$(mktemp --suffix=.json)
"${STRATA_ROOT}/.venv/bin/python" - "${config}" "$@" <<'PY'
import json, os, sys
e = os.environ
cfg = {"exe": e["STRATA_ROOT"] + "/build-halo/strata", "args": sys.argv[2:], "cwd": e["STRATA_ROOT"],
       "tokenizer": e["STRATA_TOKENIZER"], "model_name": e["STRATA_MODEL_NAME"], "log": e["STRATA_LOG"],
       "host": "0.0.0.0", "port": 8082}
# The CPU picture reader; the text model is opened for its vocabulary only.
if e.get("STRATA_VISION_MMPROJ"):
    cfg["vision"] = {"exe": e["STRATA_ROOT"] + "/build-vision/bin/strata-vision", "mmproj": e["STRATA_VISION_MMPROJ"],
                     "model": e["STRATA_VISION_MODEL"], "gpu": False, "threads": int(e.get("STRATA_VISION_THREADS", "8"))}
with open(sys.argv[1], "w") as f:
    json.dump(cfg, f, indent=2)
PY

mkdir -p "$(dirname "${STRATA_LOG}")"
cd "${STRATA_ROOT}"
exec "${STRATA_ROOT}/.venv/bin/python" -m serve.server --engine strata --config "${config}" \
    --host 0.0.0.0 --port 8082 --no-api-key
