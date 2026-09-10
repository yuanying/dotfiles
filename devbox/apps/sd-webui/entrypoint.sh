#!/usr/bin/env bash
#
# Starts sd-webui from the checkout in the working directory, with the venv
# already in it. The arguments are the webui's own, passed by compose.
#
# webui.sh is not used. It would bring nothing the arguments need: the
# checkout's own are in webui-user.sh, which exports COMMANDLINE_ARGS and then
# runs webui.sh, while webui.sh itself sources only webui.settings.sh. What it
# would bring is venv handling: it upgrades pip in the venv at every start, and
# with no venv it makes one from whichever python it finds -- in this image,
# none that the venv was built for.

set -euo pipefail

venv=${PWD}/venv
if [[ ! -x ${venv}/bin/python ]]; then
    echo "sd-webui: no venv at ${venv}; set it up from the devbox with ./webui-user.sh first" >&2
    exit 1
fi

# As upstream's image does: less fragmentation with large models.
tcmalloc=/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4
if [[ -f ${tcmalloc} ]]; then
    export LD_PRELOAD=${tcmalloc}
fi

export VIRTUAL_ENV=${venv}
export PATH=${venv}/bin:${PATH}
exec python launch.py "$@"
