# Shared setup for the repository-level tests.
#
# REPO points at the checkout under test; BATS_TEST_TMPDIR is a fresh directory
# per test, so nothing here has to clean up after itself.

REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

require() {
    if ! command -v "$1" > /dev/null 2>&1; then
        skip "$1 is not installed"
    fi
}

# A port nothing is listening on. Bound and released, so it is free right now
# rather than merely unlikely to be taken.
free_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}
