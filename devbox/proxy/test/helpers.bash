# Shared setup for the proxy wrapper tests.
#
# BATS_TEST_TMPDIR is a fresh directory per test, so nothing here cleans up
# after itself. The wrapper is driven entirely through the environment, which
# is also how it is driven in production -- entrypoint.sh sets nothing and gets
# the defaults.

PROXY_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
PROXY_BIN="${PROXY_DIR}/bin"

require() {
    if ! command -v "$1" > /dev/null 2>&1; then
        skip "$1 is not installed"
    fi
}

# proxy runs the wrapper with this test's state and declaration file, on ports
# nothing needs privileges for.
proxy() {
    DEVBOX_PROXY_STATE="${STATE}" \
    DEVBOX_PROXY_CONFIG="${CONFIG}" \
    DEVBOX_PROXY_HTTP_PORT="${HTTP_PORT}" \
    DEVBOX_PROXY_HTTPS_PORT="${HTTPS_PORT}" \
        "${PROXY_BIN}/devbox-proxy" "$@"
}

pidfile() { echo "${STATE}/run/devbox-proxyd.pid"; }

is_running() {
    local f
    f="$(pidfile)"
    [[ -f ${f} ]] && kill -0 "$(cat "${f}")" 2> /dev/null
}

# wait_until runs a command until it succeeds or the patience runs out, so the
# tests do not race a process that is still starting.
wait_until() {
    local tries=${WAIT_TRIES:-100}
    while (( tries-- > 0 )); do
        if "$@"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}
