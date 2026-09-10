#!/usr/bin/env bats

# The docker networks every devbox host has: v6net, which the devbox itself
# lives on, and sdnet, the bridge the sd containers live on. Everything about
# them is the same on every host except the IPv6 subnet of v6net and what hangs
# off it, which is the one thing devbox/network/hosts/<hostname>.env holds.
#
# docker is a stand-in: it answers `network inspect` from files in the stub's
# networks/ directory, written in the line format setup-networks asks docker
# for, and records every call.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    SCRIPT="${REPO}/devbox/network/setup-networks"
    STUB_DIR="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "${STUB_DIR}/bin" "${STUB_DIR}/networks"

    cat > "${STUB_DIR}/bin/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_DIR}/docker.calls"
if [[ $1 == network && $2 == inspect ]]; then
    name=${!#}
    if [[ ! -f ${STUB_DIR}/networks/${name} ]]; then
        echo "Error response from daemon: network ${name} not found" >&2
        exit 1
    fi
    cat "${STUB_DIR}/networks/${name}"
    exit 0
fi
if [[ $1 == network && $2 == create ]]; then
    exit 0
fi
echo "docker stub: unexpected call: $*" >&2
exit 2
EOF
    cat > "${STUB_DIR}/bin/hostname" <<'EOF'
#!/bin/bash
echo testhost
EOF
    chmod +x "${STUB_DIR}/bin/docker" "${STUB_DIR}/bin/hostname"
    export STUB_DIR
    PATH="${STUB_DIR}/bin:${PATH}"

    HOSTS="${BATS_TEST_TMPDIR}/hosts"
    mkdir -p "${HOSTS}"
    cat > "${HOSTS}/testhost.env" <<'EOF'
V6NET_SUBNET=2001:db8:1::/64
V6NET_GATEWAY=2001:db8:1::1
DEVBOX_IP6=2001:db8:1::151
EOF
    export DEVBOX_NETWORK_HOSTS="${HOSTS}"
}

standard_v6net() {
    cat > "${STUB_DIR}/networks/v6net" <<'EOF'
driver=bridge
ipv6=true
internal=false
subnet=2001:db8:1::/64 gateway=2001:db8:1::1
subnet=172.18.0.0/16 gateway=172.18.0.1
EOF
}

standard_sdnet() {
    cat > "${STUB_DIR}/networks/sdnet" <<'EOF'
driver=bridge
ipv6=false
internal=false
subnet=172.30.0.0/24 gateway=172.30.0.1
EOF
}

called() {
    grep -qxF -- "$1" "${STUB_DIR}/docker.calls"
}

created_anything() {
    grep -q '^network create' "${STUB_DIR}/docker.calls" 2> /dev/null
}

@test "a host with neither network gets both, in the standard shape" {
    run "${SCRIPT}" testhost
    [ "${status}" -eq 0 ]
    called "network create --driver bridge --ipv6 --subnet 2001:db8:1::/64 --gateway 2001:db8:1::1 --subnet 172.18.0.0/16 --gateway 172.18.0.1 v6net"
    called "network create --driver bridge --subnet 172.30.0.0/24 --gateway 172.30.0.1 sdnet"
}

@test "networks that already match are left alone" {
    standard_v6net
    standard_sdnet
    run "${SCRIPT}" testhost
    [ "${status}" -eq 0 ]
    ! created_anything
}

@test "only the missing network is created" {
    standard_v6net
    run "${SCRIPT}" testhost
    [ "${status}" -eq 0 ]
    called "network create --driver bridge --subnet 172.30.0.0/24 --gateway 172.30.0.1 sdnet"
    run grep -c '^network create' "${STUB_DIR}/docker.calls"
    [ "${output}" = 1 ]
}

@test "a network that differs is reported, not changed" {
    standard_v6net
    sed -i 's|172.18.0.0/16 gateway=172.18.0.1|172.20.0.0/16 gateway=172.20.0.1|' "${STUB_DIR}/networks/v6net"
    standard_sdnet
    run "${SCRIPT}" testhost
    [ "${status}" -ne 0 ]
    [[ ${output} == *v6net* ]]
    [[ ${output} == *172.18.0.0/16* ]]
    [[ ${output} == *172.20.0.0/16* ]]
    ! grep -qv '^network inspect' "${STUB_DIR}/docker.calls"
}

@test "an internal sdnet counts as different: the apps need to reach the internet" {
    standard_v6net
    standard_sdnet
    sed -i 's/^internal=false/internal=true/' "${STUB_DIR}/networks/sdnet"
    run "${SCRIPT}" testhost
    [ "${status}" -ne 0 ]
    [[ ${output} == *sdnet* ]]
    ! created_anything
}

@test "a difference in one network does not stop the other being created" {
    standard_v6net
    sed -i 's/^ipv6=true/ipv6=false/' "${STUB_DIR}/networks/v6net"
    run "${SCRIPT}" testhost
    [ "${status}" -ne 0 ]
    called "network create --driver bridge --subnet 172.30.0.0/24 --gateway 172.30.0.1 sdnet"
}

@test "--dry-run prints what it would create and creates nothing" {
    run "${SCRIPT}" --dry-run testhost
    [ "${status}" -eq 0 ]
    [[ ${output} == *"docker network create --driver bridge --ipv6 --subnet 2001:db8:1::/64"*v6net* ]]
    [[ ${output} == *"docker network create --driver bridge --subnet 172.30.0.0/24"*sdnet* ]]
    ! created_anything
}

@test "the host defaults to this machine's short hostname" {
    run "${SCRIPT}"
    [ "${status}" -eq 0 ]
    called "network create --driver bridge --ipv6 --subnet 2001:db8:1::/64 --gateway 2001:db8:1::1 --subnet 172.18.0.0/16 --gateway 172.18.0.1 v6net"
}

@test "a host with no file is an error, before docker is asked anything" {
    run "${SCRIPT}" nosuchhost
    [ "${status}" -ne 0 ]
    [[ ${output} == *nosuchhost* ]]
    [ ! -e "${STUB_DIR}/docker.calls" ]
}

@test "host files hold the IPv6 values and nothing else" {
    local f keys
    for f in "${REPO}"/devbox/network/hosts/*.env; do
        keys=$(grep -v -e '^#' -e '^$' "${f}" | cut -d= -f1 | sort | tr '\n' ' ')
        [ "${keys}" = "DEVBOX_IP6 V6NET_GATEWAY V6NET_SUBNET " ] || {
            echo "${f}: ${keys}"
            return 1
        }
        if grep -v -e '^#' -e '^$' "${f}" | cut -d= -f2 | grep -q -v ':'; then
            echo "${f}: a value that is not IPv6"
            return 1
        fi
    done
}

@test "each host's devbox address and gateway are inside its subnet" {
    local f prefix
    for f in "${REPO}"/devbox/network/hosts/*.env; do
        (
            # shellcheck disable=SC1090
            source "${f}"
            prefix=${V6NET_SUBNET%%::/64}:
            [[ ${V6NET_SUBNET} == *::/64 ]]
            [[ ${DEVBOX_IP6} == "${prefix}"* ]]
            [[ ${V6NET_GATEWAY} == "${prefix}"* ]]
        ) || {
            echo "${f}"
            return 1
        }
    done
}

@test "both devbox hosts have a file" {
    [ -f "${REPO}/devbox/network/hosts/boucherie.env" ]
    [ -f "${REPO}/devbox/network/hosts/anietta.env" ]
}
