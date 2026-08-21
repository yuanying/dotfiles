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
  - name: not.one.label
    port: 19999
    auth: none
YAML
    run -1 proxy reload
    [[ "${output}" == *"one label"* ]]

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

# The pid file goes away as the process exits, so testing for it and then
# reading it has a gap in the middle. stop used to spill a "No such file" from
# cat into the middle of an otherwise successful shutdown.
@test "stop is quiet about the pid file it is watching disappear" {
    run -0 proxy start
    wait_until is_running

    run -0 proxy stop
    [[ "${output}" != *"No such file"* ]]
}

# ---------------------------------------------------------------------------
# The overlay in the state directory (docs/adr/0009)
# ---------------------------------------------------------------------------

authenticated_config() {
    cat > "${CONFIG}" <<'YAML'
zone: example.test
services:
  - name: thing
    port: 19999
    auth: required
YAML
}

overlay() {
    mkdir -p "${STATE}"
    cat > "${STATE}/services.local.yaml"
}

@test "the overlay adds viewers to a declared service" {
    authenticated_config
    overlay <<'YAML'
services:
  - name: thing
    viewers:
      logins: [someone]
YAML
    run -0 proxy check
    [[ "${output}" == *"1 viewer"* ]]
    [[ "${output}" == *"services.local.yaml"* ]]
}

@test "the overlay adds to what the declaration already lists" {
    cat > "${CONFIG}" <<'YAML'
zone: example.test
services:
  - name: thing
    port: 19999
    auth: required
    viewers:
      logins: [declared]
YAML
    overlay <<'YAML'
services:
  - name: thing
    viewers:
      logins: [private]
YAML
    run -0 proxy check
    [[ "${output}" == *"2 viewer"* ]]
}

# The reason the overlay holds whole services and not just viewers: something
# the repository never hears about.
@test "the overlay can publish a service the declaration never mentions" {
    overlay <<'YAML'
services:
  - name: private
    port: 19998
    auth: none
YAML
    run -0 proxy check
    [[ "${output}" == *"private.example.test"* ]]
    [[ "${output}" == *"19998"* ]]
}

@test "the overlay can move a port without touching the repository" {
    overlay <<'YAML'
services:
  - name: thing
    port: 19001
YAML
    run -0 proxy check
    [[ "${output}" == *"19001"* ]]
}

@test "the merged result is validated, not just each half" {
    overlay <<'YAML'
services:
  - name: other
    port: 19999
    auth: none
YAML
    run -1 proxy check
    [[ "${output}" == *"port 19999"* ]]
}

@test "an overlay service with no port is refused" {
    overlay <<'YAML'
services:
  - name: private
    auth: none
YAML
    run -1 proxy check
    [[ "${output}" == *"port"* ]]
}

# The zone would move every hostname and every certificate at once.
@test "the overlay cannot name a zone" {
    overlay <<'YAML'
zone: elsewhere.test
services: []
YAML
    run -1 proxy check
}

# The operator chose that a service nobody can reach still starts. Something
# has to say so, or the first sign is a login that can never succeed.
@test "a service nobody can reach starts, with a warning" {
    authenticated_config
    run -0 proxy check
    [[ "${output}" == *"nobody"* ]]

    run -0 proxy warnings
    [[ "${output}" == *"thing.example.test"* ]]

    run -0 proxy start
    wait_until is_running
    is_running
}

@test "no overlay is the ordinary case, not an error" {
    [[ ! -e ${STATE}/services.local.yaml ]]
    run -0 proxy check
}

@test "the overlay is picked up by reload" {
    run -0 proxy start
    wait_until is_running
    local pid
    pid="$(cat "$(pidfile)")"

    overlay <<'YAML'
services:
  - name: private
    port: 19998
    auth: none
YAML
    run -0 proxy reload
    [[ "$(cat "$(pidfile)")" == "${pid}" ]]
    is_running
}

# docs/adr/0010: bearer tokens for clients that are not browsers.

guarded_config() {
    cat > "${CONFIG}" <<'YAML'
zone: example.test
services:
  - name: thing
    port: 19999
    auth: none
  - name: llama
    port: 19998
    auth: required
    viewers:
      logins:
        - yuanying
YAML
}

@test "token prints a bearer token for a service that asks for a login" {
    guarded_config
    run -0 proxy token --service llama --user yuanying
    [[ "${output}" == *.* ]]
    [[ "${output}" != *" "* ]]
}

@test "token refuses a service that asks for no login" {
    guarded_config
    run -1 proxy token --service thing --user yuanying
    [[ "${output}" == *"attest to nothing"* ]]
}

@test "token refuses a service that is not published" {
    guarded_config
    run -1 proxy token --service nowhere --user yuanying
    [[ "${output}" == *"not published"* ]]
}

@test "token needs to know who it is for" {
    guarded_config
    run -1 proxy token --service llama
    [[ "${output}" == *"--user"* ]]
}

# The second key is the whole of docs/adr/0010's revocation story, so it has to
# be a file of its own that nothing else writes.
@test "token signs with a key that is not the session key" {
    guarded_config
    run -0 proxy token --service llama --user yuanying
    [[ -f "${STATE}/api.key" ]]
    run -0 stat -c '%a' "${STATE}/api.key"
    [[ "${output}" == "600" ]]
    [[ ! -f "${STATE}/session.key" ]]
}

@test "two tokens for the same service are not the same token" {
    guarded_config
    run -0 proxy token --service llama --user yuanying --ttl 1h
    local first="${output}"
    run -0 proxy token --service llama --user yuanying --ttl 2h
    [[ "${output}" != "${first}" ]]
}
