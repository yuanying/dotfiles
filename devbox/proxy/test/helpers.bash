# Shared setup for the proxy tests.
#
# PROXY_BIN / FIXTURES point at the tree under test; BATS_TEST_TMPDIR is a fresh
# directory per test, so nothing here has to clean up after itself.

PROXY_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
PROXY_BIN="${PROXY_DIR}/bin"
FIXTURES="${BATS_TEST_DIRNAME}/fixtures"

# Every path in the generated files derives from the state directory, so the
# tests pin it to a fixed string and compare bytes. --write-to only decides
# where the bytes land.
STATE_DIR=/state

generate() {
    "${PROXY_BIN}/generate-traefik-config.sh" \
        --config "$1" \
        --state-dir "${STATE_DIR}" \
        --write-to "$2"
}

# Fail with a diff rather than "files differ", which says nothing useful.
assert_same_file() {
    if ! diff -u "$1" "$2"; then
        echo "generated output does not match ${1}" >&2
        return 1
    fi
}

require() {
    if ! command -v "$1" > /dev/null 2>&1; then
        skip "$1 is not installed"
    fi
}
