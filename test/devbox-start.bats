#!/usr/bin/env bats

# The start scripts put the devbox on v6net at its fixed address and on sdnet
# as a second network. The address comes from the host file, not from the
# script, and sdnet must not take the default route away from v6net.
#
# docker is a stand-in that records one argument per line.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    STUB_DIR="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "${STUB_DIR}/bin"
    cat > "${STUB_DIR}/bin/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "${STUB_DIR}/docker.args"
EOF
    chmod +x "${STUB_DIR}/bin/docker"
    export STUB_DIR
    PATH="${STUB_DIR}/bin:${PATH}"
}

arg() {
    grep -qxF -- "$1" "${STUB_DIR}/docker.args"
}

# network_args prints the value of every --network, one per line.
network_args() {
    awk 'prev == "--network" { print } { prev = $0 }' "${STUB_DIR}/docker.args"
}

host_value() {
    (
        # shellcheck disable=SC1090
        source "${REPO}/devbox/network/hosts/$1.env"
        eval "echo \"\${$2}\""
    )
}

@test "start-cuda puts the boucherie devbox on v6net at the address in its host file" {
    run "${REPO}/devbox/start-cuda"
    [ "${status}" -eq 0 ]
    arg "--hostname=boucherie"
    arg "name=v6net,ip6=$(host_value boucherie DEVBOX_IP6)"
    [ "$(host_value boucherie DEVBOX_IP6)" = "2405:6581:8580:302::151" ]
}

@test "start-cuda also joins sdnet, below v6net for the default route" {
    run "${REPO}/devbox/start-cuda"
    [ "${status}" -eq 0 ]
    run network_args
    [ "${output}" = "name=v6net,ip6=2405:6581:8580:302::151
name=sdnet,gw-priority=-1" ]
}

@test "start-cuda no longer carries an address of its own" {
    run "${REPO}/devbox/start-cuda"
    ! arg "--ip6"
    ! grep -q '2405:' "${REPO}/devbox/start-cuda"
}

@test "start-rocm does the same for anietta" {
    run "${REPO}/devbox/start-rocm"
    [ "${status}" -eq 0 ]
    arg "--hostname=anietta"
    [ "$(host_value anietta DEVBOX_IP6)" = "2405:6581:8580:310::153" ]
    run network_args
    [ "${output}" = "name=v6net,ip6=2405:6581:8580:310::153
name=sdnet,gw-priority=-1" ]
    ! grep -q '2405:' "${REPO}/devbox/start-rocm"
}
