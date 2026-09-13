#!/usr/bin/env bats

# The start scripts put the devbox on v6net and nothing else.
#
# start-cuda (boucherie, on poissonnerie) and start-rocm (anietta, on simone)
# are on hosts whose v6net is regied's bridge, made by net-fraction-private with
# IPv4 only. The devbox keeps IPv6 on eth0 with a driver option and takes its
# address from the RA and a token, which the entrypoint sets (docs/adr/0012,
# revision of 2026-09-13). No docker network is defined in this repository.
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

@test "start-cuda puts boucherie on v6net with IPv6 kept on, and nothing else" {
    run "${REPO}/devbox/start-cuda"
    [ "${status}" -eq 0 ]
    arg "--hostname=boucherie"
    run network_args
    [ "${output}" = "name=v6net,driver-opt=com.docker.network.endpoint.sysctls=net.ipv6.conf.IFNAME.disable_ipv6=0" ]
}

@test "start-cuda hands the entrypoint the token, not an address" {
    run "${REPO}/devbox/start-cuda"
    [ "${status}" -eq 0 ]
    arg "DEVBOX_IP6_TOKEN=::151"
    ! arg "--ip6"
    ! grep -q '2405:' "${REPO}/devbox/start-cuda"
    ! grep -q 'ip6=' "${REPO}/devbox/start-cuda"
}

@test "start-cuda keeps the GPU and /mnt" {
    run "${REPO}/devbox/start-cuda"
    [ "${status}" -eq 0 ]
    arg "--gpus"
    arg "all"
    arg "type=bind,source=/mnt,target=/mnt,bind-propagation=slave"
    arg "registry.fraction.jp/yuanying/devbox-cuda:latest"
}

@test "start-cuda does not read devbox/network" {
    ! grep -q 'network/' "${REPO}/devbox/start-cuda"
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

@test "no docker network is defined in this repository any more" {
    [ ! -e "${REPO}/devbox/network" ]
}
