#!/usr/bin/env bats

# The wrapper: docs/adr/0008.
#
# Two properties matter more than the rest. The proxy must never be the reason
# the devbox fails to come up -- no declaration file is a skip, not an error --
# and a reload that does not validate must leave what is running alone.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    require go

    STATE="${BATS_TEST_TMPDIR}/state"
    CONFIG="${BATS_TEST_TMPDIR}/services.yaml"
    # Ports nothing else on the machine is likely to want, and above 1024 so
    # the wrapper does not reach for setcap.
    HTTP_PORT=18080
    HTTPS_PORT=18443

    cat > "${CONFIG}" <<'YAML'
zone: example.test
services:
  - name: thing
    port: 19999
    auth: none
YAML
}

teardown() {
    if [[ -n ${STATE:-} && -f ${STATE}/run/devbox-proxyd.pid ]]; then
        kill "$(cat "${STATE}/run/devbox-proxyd.pid")" 2> /dev/null || true
    fi
}

binary() {
    find "${STATE}/bin" -name devbox-proxyd -type f 2> /dev/null | head -1
}

@test "build compiles the binary when there is none" {
    run -0 proxy build
    [[ -n "$(binary)" ]]
    [[ -x "$(binary)" ]]
}

@test "build is skipped when nothing has changed" {
    run -0 proxy build
    local first
    first="$(binary)"
    local before
    before="$(stat -c %Y "${first}")"

    run -0 proxy build
    [[ "$(stat -c %Y "${first}")" == "${before}" ]]
}

@test "build happens again when a source file is newer" {
    run -0 proxy build
    local bin
    bin="$(binary)"
    local before
    before="$(stat -c %Y "${bin}")"

    # Touching a source is what a `git pull` looks like from here.
    sleep 1.1
    touch "${PROXY_DIR}/proxyd/main.go"

    run -0 proxy build
    [[ "$(stat -c %Y "${bin}")" != "${before}" ]]
}

@test "start brings it up and writes a pid file" {
    run -0 proxy start
    wait_until is_running
    is_running
}

@test "stop takes it down" {
    run -0 proxy start
    wait_until is_running

    run -0 proxy stop
    ! is_running
}

@test "starting twice is not an accident" {
    run -0 proxy start
    wait_until is_running
    local first
    first="$(cat "$(pidfile)")"

    run -0 proxy start
    [[ "$(cat "$(pidfile)")" == "${first}" ]]
    is_running
}

@test "stopping something that is not running is fine" {
    run -0 proxy stop
}

# docs/adr/0006 and 0008: no certificate is not a reason to refuse to start.
@test "it starts with no certificates and no credentials" {
    [[ ! -e ${STATE}/certs ]]
    run -0 proxy start
    wait_until is_running
    is_running
}

# docs/adr/0001, kept by 0008: entrypoint.sh calls this on every boot.
@test "a host with no declaration file starts nothing and succeeds" {
    rm "${CONFIG}"
    run -0 proxy start
    ! is_running
    [[ "${output}" == *"no declaration file"* ]]
}

@test "check accepts a good declaration file" {
    run -0 proxy check
    [[ "${output}" == *"thing.example.test"* ]]
}

@test "check refuses a bad one and says why" {
    cat > "${CONFIG}" <<'YAML'
zone: example.test
services:
  - name: not.one.label
    port: 19999
    auth: none
YAML
    run -1 proxy check
    [[ "${output}" == *"one label"* ]]
}

@test "reload applies a declaration file that validates" {
    run -0 proxy start
    wait_until is_running
    local pid
    pid="$(cat "$(pidfile)")"

    cat >> "${CONFIG}" <<'YAML'
  - name: another
    port: 19998
    auth: none
YAML
    run -0 proxy reload

    # Same process: 0008 wants the listeners and every established connection
    # to survive a reload.
    [[ "$(cat "$(pidfile)")" == "${pid}" ]]
    is_running
}

@test "a reload that does not validate changes nothing and leaves it running" {
    run -0 proxy start
    wait_until is_running
    local pid
    pid="$(cat "$(pidfile)")"

    cat > "${CONFIG}" <<'YAML'
zone: example.test
services:
  - name: thing
    port: 19999
    auth: required
YAML
    run -1 proxy reload
    [[ "${output}" == *"viewer"* ]]

    is_running
    [[ "$(cat "$(pidfile)")" == "${pid}" ]]
}

@test "reload without anything running says so rather than failing" {
    run -0 proxy reload
    [[ "${output}" == *"not running"* ]]
}

@test "restart replaces the process" {
    run -0 proxy start
    wait_until is_running
    local first
    first="$(cat "$(pidfile)")"

    run -0 proxy restart
    wait_until is_running
    [[ "$(cat "$(pidfile)")" != "${first}" ]]
}

@test "status answers while it is stopped" {
    run -0 proxy status
    [[ "${output}" == *"not running"* ]]
    [[ "${output}" == *"thing.example.test"* ]]
}

@test "status says what is running" {
    run -0 proxy start
    wait_until is_running

    run -0 proxy status
    [[ "${output}" == *"running"* ]]
    [[ "${output}" == *"$(cat "$(pidfile)")"* ]]
}

@test "status with no declaration file does not blow up" {
    rm "${CONFIG}"
    run -0 proxy status
    [[ "${output}" == *"no declaration file"* ]]
}

# entrypoint.sh pipes this into the container's log on every boot, so it has to
# be silent unless something is actually wrong (docs/adr/0006).
@test "warnings says nothing on a devbox with no certificates yet" {
    run -0 proxy build
    run -0 proxy warnings
    [ -z "${output}" ]
}

@test "warnings says nothing when there is no declaration file" {
    rm "${CONFIG}"
    run -0 proxy warnings
    [ -z "${output}" ]
}
