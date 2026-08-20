#!/usr/bin/env bats

# The proxy must never be the reason the devbox fails to come up: a missing
# certificate or a missing declaration file is a skip, not an error.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    require yq
    require jq
    require openssl

    STATE="${BATS_TEST_TMPDIR}/state"
    CONFIG="${BATS_TEST_TMPDIR}/services.yaml"
    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${FAKE_BIN}"

    # Stand-ins for the real daemons: they record how they were called and then
    # stay alive so that the pid files mean something.
    cat > "${FAKE_BIN}/traefik" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "${BATS_TEST_TMPDIR}/traefik.args"
exec sleep 300
EOF
    chmod +x "${FAKE_BIN}/traefik"

    export PATH="${FAKE_BIN}:${PATH}"
    export DEVBOX_PROXY_STATE="${STATE}"
    export DEVBOX_PROXY_CONFIG="${CONFIG}"
    # Binding :443 needs root in real life; the tests do not bind anything.
    export DEVBOX_PROXY_SUDO=""

    cp "${FIXTURES}/basic/services.yaml" "${CONFIG}"
}

teardown() {
    "${PROXY_BIN}/devbox-proxy" stop > /dev/null 2>&1
    return 0
}

install_cert() {
    mkdir -p "${STATE}/certs"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=*.example.org' \
        -keyout "${STATE}/certs/origin.key" -out "${STATE}/certs/origin.pem" 2> /dev/null
}

running() {
    local pidfile="${STATE}/run/$1.pid"
    [ -f "${pidfile}" ] && kill -0 "$(cat "${pidfile}")" 2> /dev/null
}

@test "start without a certificate skips instead of failing" {
    run "${PROXY_BIN}/devbox-proxy" start
    [ "$status" -eq 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/traefik.args" ]
}

@test "start without a declaration file skips instead of failing" {
    install_cert
    rm "${CONFIG}"
    run "${PROXY_BIN}/devbox-proxy" start
    [ "$status" -eq 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/traefik.args" ]
}

@test "a skipped start keeps stdout clean but still says why" {
    # On boot stdout belongs to entrypoint.sh, so the reason goes to stderr.
    run --separate-stderr "${PROXY_BIN}/devbox-proxy" start
    [ -z "$output" ]
    [[ "$stderr" == *"certificate"* ]]
}

@test "start brings up traefik against the generated config" {
    install_cert
    run "${PROXY_BIN}/devbox-proxy" start
    [ "$status" -eq 0 ]
    grep -q -- "--configFile=${STATE}/traefik/traefik.yml" "${BATS_TEST_TMPDIR}/traefik.args"
    [ -f "${STATE}/traefik/dynamic/services.yml" ]
    running traefik
}

@test "start brings up the verifier when a service needs authentication" {
    install_cert
    "${PROXY_BIN}/devbox-proxy" start
    running forwardauth
}

@test "the verifier is not started when nothing needs authentication" {
    install_cert
    cat > "${CONFIG}" <<'EOF'
zone: example.org
services:
  - name: sd
    port: 7860
    auth: none
EOF
    "${PROXY_BIN}/devbox-proxy" start
    ! running forwardauth
}

@test "a declaration file that does not validate fails loudly and starts nothing" {
    install_cert
    cat > "${CONFIG}" <<'EOF'
zone: example.org
services:
  - name: llama.gpu
    port: 8081
    auth: none
EOF
    run "${PROXY_BIN}/devbox-proxy" start
    [ "$status" -ne 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/traefik.args" ]
}

@test "stop is fine when nothing is running" {
    run "${PROXY_BIN}/devbox-proxy" stop
    [ "$status" -eq 0 ]
}

@test "stop takes both daemons down" {
    install_cert
    "${PROXY_BIN}/devbox-proxy" start
    running traefik
    running forwardauth
    "${PROXY_BIN}/devbox-proxy" stop
    ! running traefik
    ! running forwardauth
}

@test "status reports both states without failing" {
    run "${PROXY_BIN}/devbox-proxy" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"traefik"* ]]
    install_cert
    "${PROXY_BIN}/devbox-proxy" start
    run "${PROXY_BIN}/devbox-proxy" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"running"* ]]
}

@test "status names the certificate expiry, because nothing else will" {
    install_cert
    run "${PROXY_BIN}/devbox-proxy" status
    [[ "$output" == *"expires"* ]]
}

@test "a second start does not leave two traefiks behind" {
    install_cert
    "${PROXY_BIN}/devbox-proxy" start
    local first
    first=$(cat "${STATE}/run/traefik.pid")
    "${PROXY_BIN}/devbox-proxy" start
    [ "$(cat "${STATE}/run/traefik.pid")" = "${first}" ]
}

@test "an unknown subcommand is an error" {
    run "${PROXY_BIN}/devbox-proxy" frobnicate
    [ "$status" -ne 0 ]
}
