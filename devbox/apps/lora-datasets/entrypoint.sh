#!/usr/bin/env bash
#
# Runs the lora-datasets UI from the checkout in the working directory, on
# every interface of the container: proxyd reaches it over v6net, and the
# UI has no login of its own.
#
# --frozen keeps uv from rewriting uv.lock; the venv is synced to it as it
# would be by `uv run` in the devbox.

set -euo pipefail

exec uv run --frozen lora-datasets ui --host 0.0.0.0 --port 8765
