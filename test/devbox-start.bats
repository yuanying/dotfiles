#!/usr/bin/env bats

# The start scripts put the devbox on v6net.
#
# start-cuda (boucherie, on poissonnerie) is on a host whose v6net docker still
# makes from devbox/network: a fixed address from the host file, and sdnet as a
# second network that must not take the default route away from v6net.
#
# start-rocm (anietta, on simone) is on a host whose v6net is regied's bridge,
# made by net-fraction-private with IPv4 only. The devbox keeps IPv6 on eth0
# with a driver option and takes its address from the RA and a token, which the
# entrypoint sets (docs/adr/0012, revision of 2026-09-13).
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

@test "start-rocm puts anietta on v6net with IPv6 kept on, and nothing else" {
    run "${REPO}/devbox/start-rocm"
    [ "${status}" -eq 0 ]
    arg "--hostname=anietta"
    run network_args
    [ "${output}" = "name=v6net,driver-opt=com.docker.network.endpoint.sysctls=net.ipv6.conf.IFNAME.disable_ipv6=0" ]
}

@test "start-rocm hands the entrypoint the token, not an address" {
    run "${REPO}/devbox/start-rocm"
    [ "${status}" -eq 0 ]
    arg "DEVBOX_IP6_TOKEN=::153"
    ! grep -q '2405:' "${REPO}/devbox/start-rocm"
    ! grep -q 'ip6=' "${REPO}/devbox/start-rocm"
}

@test "start-rocm does not read devbox/network" {
    ! grep -q 'network/' "${REPO}/devbox/start-rocm"
}
