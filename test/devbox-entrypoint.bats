#!/usr/bin/env bats

# The parts of devbox/entrypoint.sh that must not take the host down with them.
# $HOME is the host's, bind-mounted, so a failure while writing
# ~/.ssh/authorized_keys locks the host out, not only the container. And the
# devbox's IPv6 address on a host whose v6net is regied's comes from the RA and
# a token the entrypoint sets on every start.
#
# The script is sourced: it defines its steps as functions and runs them only
# when executed. curl and sudo are stand-ins that record their arguments.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    STUB_DIR="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "${STUB_DIR}/bin"
    cat > "${STUB_DIR}/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_DIR}/curl.calls"
out=
while (($#)); do
    [[ $1 == -o ]] && { out=$2; shift; }
    shift
done
case ${CURL_STUB:-ok} in
    ok) body="ssh-ed25519 AAAAnew key" ;;
    empty) body= ;;
    fail) exit 6 ;;
esac
if [[ -n ${out} ]]; then
    printf '%s' "${body}" > "${out}"
else
    printf '%s' "${body}"
fi
EOF
    cat > "${STUB_DIR}/bin/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_DIR}/sudo.calls"
exit "${SUDO_STUB_STATUS:-0}"
EOF
    chmod +x "${STUB_DIR}/bin/curl" "${STUB_DIR}/bin/sudo"
    export STUB_DIR
    PATH="${STUB_DIR}/bin:${PATH}"

    HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}/.ssh"
    printf 'ssh-ed25519 AAAAold key\n' > "${HOME}/.ssh/authorized_keys"
    export HOME

    unset DEVBOX_IP6_TOKEN
    # shellcheck source=../devbox/entrypoint.sh
    source "${REPO}/devbox/entrypoint.sh"
}

@test "sourcing the entrypoint runs nothing" {
    [ ! -e "${STUB_DIR}/curl.calls" ]
    [ ! -e "${STUB_DIR}/sudo.calls" ]
}

@test "the keys from GitHub replace authorized_keys" {
    run install_authorized_keys
    [ "${status}" -eq 0 ]
    [ "$(cat "${HOME}/.ssh/authorized_keys")" = "ssh-ed25519 AAAAnew key" ]
    [ "$(stat -c %a "${HOME}/.ssh/authorized_keys")" = 600 ]
    [ "$(stat -c %a "${HOME}/.ssh")" = 700 ]
}

@test "a failed download leaves authorized_keys as it was, and says so" {
    CURL_STUB=fail run install_authorized_keys
    [ "$(cat "${HOME}/.ssh/authorized_keys")" = "ssh-ed25519 AAAAold key" ]
    [[ ${output} == *authorized_keys* ]]
}

@test "an empty download leaves authorized_keys as it was" {
    CURL_STUB=empty run install_authorized_keys
    [ "$(cat "${HOME}/.ssh/authorized_keys")" = "ssh-ed25519 AAAAold key" ]
    [[ ${output} == *authorized_keys* ]]
}

@test "nothing is left behind in ~/.ssh either way" {
    CURL_STUB=fail run install_authorized_keys
    run install_authorized_keys
    [ "$(ls -A "${HOME}/.ssh")" = authorized_keys ]
}

@test "a host with no ~/.ssh yet gets the keys" {
    rm -rf "${HOME}/.ssh"
    run install_authorized_keys
    [ "$(cat "${HOME}/.ssh/authorized_keys")" = "ssh-ed25519 AAAAnew key" ]
}

@test "with DEVBOX_IP6_TOKEN, the token is set on eth0" {
    DEVBOX_IP6_TOKEN=::153 run set_ip6_token
    [ "${status}" -eq 0 ]
    [ "$(cat "${STUB_DIR}/sudo.calls")" = "ip token set ::153 dev eth0" ]
}

@test "without DEVBOX_IP6_TOKEN, nothing is touched" {
    run set_ip6_token
    [ "${status}" -eq 0 ]
    [ ! -e "${STUB_DIR}/sudo.calls" ]
}

@test "a token that cannot be set is a warning, not the end of the start" {
    DEVBOX_IP6_TOKEN=::153 SUDO_STUB_STATUS=2 run set_ip6_token
    [ "${status}" -eq 0 ]
    [[ ${output} == *::153* ]]
}

@test "the token is set before the keys are fetched and before sshd" {
    local script="${REPO}/devbox/entrypoint.sh" guard token keys sshd
    guard=$(grep -n '^\[\[ \${BASH_SOURCE\[0\]} == "\$0" \]\] || return 0$' "${script}" | cut -d: -f1)
    token=$(grep -n '^set_ip6_token$' "${script}" | cut -d: -f1)
    keys=$(grep -n '^install_authorized_keys$' "${script}" | cut -d: -f1)
    sshd=$(grep -n 'sshd -D' "${script}" | cut -d: -f1)
    [ -n "${guard}" ] && [ -n "${token}" ] && [ -n "${keys}" ] && [ -n "${sshd}" ]
    [ "${guard}" -lt "${token}" ]
    [ "${token}" -lt "${keys}" ]
    [ "${keys}" -lt "${sshd}" ]
}
