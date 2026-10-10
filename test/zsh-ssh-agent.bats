#!/usr/bin/env bats

# zsh.d/12_ssh_agent.zsh gives a Linux shell an ssh-agent when it has none.
# The devbox has no systemd, so nothing else starts one, and `ssh -A` from
# there forwards nothing without it.
#
# The agent lives at a fixed socket so that every shell -- and every shell
# opened later -- shares one. What the tests pin down:
#   - an agent the shell can already reach (forwarded from a Mac) wins;
#   - a live agent at the fixed socket is reused, never doubled;
#   - a dead socket left behind is replaced by a fresh agent;
#   - shells starting at the same moment still end up with one agent;
#   - a Mac, which has launchd's agent, is left alone.
#
# ssh-agent and ssh-add are fakes. The "socket" is a plain file whose content
# says whether the agent behind it is alive, and every start is logged, so
# "how many agents" is the number of lines in the log.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    require zsh
    SNIPPET="${REPO}/zsh.d/12_ssh_agent.zsh"
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    SOCK="${HOME}/.ssh/agent/agent.sock"
    export STARTS="${BATS_TEST_TMPDIR}/starts"
    : > "${STARTS}"

    FAKEBIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${FAKEBIN}"
    cat > "${FAKEBIN}/ssh-agent" <<'EOF'
#!/bin/bash
# ssh-agent -a SOCK: refuses an existing path, as bind(2) does.
[ "$1" = "-a" ] || exit 64
if [ -e "$2" ]; then
    echo "bind: Address already in use" >&2
    exit 1
fi
echo alive > "$2"
echo "$2" >> "${STARTS}"
echo "SSH_AUTH_SOCK=$2; export SSH_AUTH_SOCK;"
echo "echo Agent pid 4242;"
EOF
    cat > "${FAKEBIN}/ssh-add" <<'EOF'
#!/bin/bash
# ssh-add -l: 1 is "agent reachable, no keys", 2 is "cannot connect".
[ "$1" = "-l" ] || exit 64
if [ -n "${SSH_AUTH_SOCK}" ] && [ "$(cat "${SSH_AUTH_SOCK}" 2>/dev/null)" = alive ]; then
    echo "The agent has no identities."
    exit 1
fi
# A slow answer widens the gap between "it is dead" and acting on it.
sleep "${FAKE_ADD_DELAY:-0}"
echo "Could not open a connection to your authentication agent." >&2
exit 2
EOF
    chmod +x "${FAKEBIN}/ssh-agent" "${FAKEBIN}/ssh-add"
    export PATH="${FAKEBIN}:${PATH}"
}

# Source the snippet in a fresh zsh and print the socket it settled on.
load_snippet() {
    zsh -f -c "source '${SNIPPET}'; print -r -- \"\${SSH_AUTH_SOCK}\""
}

starts() {
    grep -c . "${STARTS}" || true
}

@test "with no agent, one is started at the fixed socket" {
    unset SSH_AUTH_SOCK
    run load_snippet
    [ "$status" -eq 0 ]
    [ "$output" = "${SOCK}" ]
    [ "$(starts)" -eq 1 ]
}

@test "the socket directory is private to the user" {
    unset SSH_AUTH_SOCK
    run load_snippet
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "${HOME}/.ssh/agent")" = 700 ]
}

@test "a reachable SSH_AUTH_SOCK, such as a forwarded one, is kept" {
    forwarded="${BATS_TEST_TMPDIR}/forwarded.sock"
    echo alive > "${forwarded}"
    export SSH_AUTH_SOCK="${forwarded}"
    run load_snippet
    [ "$status" -eq 0 ]
    [ "$output" = "${forwarded}" ]
    [ "$(starts)" -eq 0 ]
}

@test "an unreachable SSH_AUTH_SOCK falls back to the fixed socket" {
    export SSH_AUTH_SOCK="${BATS_TEST_TMPDIR}/gone.sock"
    run load_snippet
    [ "$status" -eq 0 ]
    [ "$output" = "${SOCK}" ]
    [ "$(starts)" -eq 1 ]
}

@test "a live agent at the fixed socket is reused" {
    unset SSH_AUTH_SOCK
    mkdir -p "$(dirname "${SOCK}")"
    echo alive > "${SOCK}"
    run load_snippet
    [ "$status" -eq 0 ]
    [ "$output" = "${SOCK}" ]
    [ "$(starts)" -eq 0 ]
}

@test "a dead socket left behind is removed and a new agent started" {
    unset SSH_AUTH_SOCK
    mkdir -p "$(dirname "${SOCK}")"
    echo dead > "${SOCK}"
    run load_snippet
    [ "$status" -eq 0 ]
    [ "$output" = "${SOCK}" ]
    [ "$(cat "${SOCK}")" = alive ]
    [ "$(starts)" -eq 1 ]
}

@test "loading it again and again leaves one agent" {
    unset SSH_AUTH_SOCK
    for _ in 1 2 3; do
        run load_snippet
        [ "$status" -eq 0 ]
        [ "$output" = "${SOCK}" ]
    done
    [ "$(starts)" -eq 1 ]
}

@test "shells starting together over a dead socket still start one agent" {
    unset SSH_AUTH_SOCK
    mkdir -p "$(dirname "${SOCK}")"
    echo dead > "${SOCK}"
    export FAKE_ADD_DELAY=0.2
    pids=()
    for i in 1 2 3 4 5; do
        load_snippet > "${BATS_TEST_TMPDIR}/out.${i}" &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "${pid}"
    done
    [ "$(starts)" -eq 1 ]
    for i in 1 2 3 4 5; do
        [ "$(cat "${BATS_TEST_TMPDIR}/out.${i}")" = "${SOCK}" ]
    done
}

@test "the snippet prints nothing" {
    unset SSH_AUTH_SOCK
    run --separate-stderr load_snippet
    [ "$status" -eq 0 ]
    [ "$output" = "${SOCK}" ]
    [ -z "$stderr" ]
}

@test "on a Mac nothing is started" {
    unset SSH_AUTH_SOCK
    run zsh -f -c "OSTYPE=darwin23.0; source '${SNIPPET}'; print -r -- \"\${SSH_AUTH_SOCK}\""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(starts)" -eq 0 ]
    [ ! -e "${HOME}/.ssh/agent" ]
}

@test "the snippet leaves no helper functions or variables behind" {
    unset SSH_AUTH_SOCK
    run zsh -f -c "source '${SNIPPET}'; typeset -m '_ssh_agent*'; functions -m '_ssh_agent*'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "github.com adds its key to the agent when used" {
    run awk '/^Host /{host=$2} host=="github.com" && $1=="AddKeysToAgent"{print $2}' "${REPO}/sshconfig"
    [ "$status" -eq 0 ]
    [ "$output" = yes ]
}
