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
#   - a Mac, which has launchd's agent, is left alone;
#   - an agent the snippet starts gets the GitHub key -- only that one, so a
#     host the agent is forwarded to cannot use the others -- and an agent it
#     merely finds is left as it is;
#   - a key with a passphrase is skipped without asking.
#
# Most tests use fakes for ssh, ssh-agent and ssh-add. The "socket" is a plain file whose content
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
    export ADDS="${BATS_TEST_TMPDIR}/adds"
    : > "${ADDS}"
    # What `ssh -G github.com` lists, in the order ssh tries them.
    export FAKE_IDENTITIES='~/.ssh/id_rsa ~/.ssh/id_ecdsa ~/.ssh/id_ed25519'

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
# ssh-add [-q] KEY: logs the key it was asked to load.
# ssh-add -l: 1 is "agent reachable, no keys", 2 is "cannot connect".
[ "$1" = "-q" ] && shift
if [ "$1" != "-l" ]; then
    [ "$(cat "${SSH_AUTH_SOCK}" 2>/dev/null)" = alive ] || exit 2
    [ -f "$1" ] || exit 1
    echo "$1" >> "${ADDS}"
    exit 0
fi
if [ -n "${SSH_AUTH_SOCK}" ] && [ "$(cat "${SSH_AUTH_SOCK}" 2>/dev/null)" = alive ]; then
    echo "The agent has no identities."
    exit 1
fi
# A slow answer widens the gap between "it is dead" and acting on it.
sleep "${FAKE_ADD_DELAY:-0}"
echo "Could not open a connection to your authentication agent." >&2
exit 2
EOF
    cat > "${FAKEBIN}/ssh" <<'EOF'
#!/bin/bash
# ssh -G HOST: prints the resolved config, identity files unexpanded.
[ "$1" = "-G" ] || exit 64
echo "hostname ssh.github.com"
for f in ${FAKE_IDENTITIES}; do
    echo "identityfile ${f}"
done
EOF
    chmod +x "${FAKEBIN}/ssh-agent" "${FAKEBIN}/ssh-add" "${FAKEBIN}/ssh"
    export PATH="${FAKEBIN}:${PATH}"
}

# Source the snippet in a fresh zsh and print the socket it settled on.
load_snippet() {
    zsh -f -c "source '${SNIPPET}'; print -r -- \"\${SSH_AUTH_SOCK}\""
}

starts() {
    grep -c . "${STARTS}" || true
}

adds() {
    grep -c . "${ADDS}" || true
}

# Give HOME the named keys (the fakes only look at whether the file exists).
keys() {
    mkdir -p "${HOME}/.ssh"
    for k in "$@"; do
        echo key > "${HOME}/.ssh/${k}"
    done
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

@test "a new agent gets the first identity file ssh would try for github.com" {
    unset SSH_AUTH_SOCK
    keys id_ecdsa id_ed25519
    run load_snippet
    [ "$status" -eq 0 ]
    [ "$output" = "${SOCK}" ]
    [ "$(cat "${ADDS}")" = "${HOME}/.ssh/id_ecdsa" ]
}

@test "an agent started over a dead socket gets the key too" {
    unset SSH_AUTH_SOCK
    keys id_rsa
    mkdir -p "$(dirname "${SOCK}")"
    echo dead > "${SOCK}"
    run load_snippet
    [ "$status" -eq 0 ]
    [ "$(cat "${ADDS}")" = "${HOME}/.ssh/id_rsa" ]
}

@test "a live agent at the fixed socket is not given keys" {
    unset SSH_AUTH_SOCK
    keys id_rsa
    mkdir -p "$(dirname "${SOCK}")"
    echo alive > "${SOCK}"
    run load_snippet
    [ "$status" -eq 0 ]
    [ "$(adds)" -eq 0 ]
}

@test "a forwarded agent is not given keys" {
    keys id_rsa
    forwarded="${BATS_TEST_TMPDIR}/forwarded.sock"
    echo alive > "${forwarded}"
    export SSH_AUTH_SOCK="${forwarded}"
    run load_snippet
    [ "$status" -eq 0 ]
    [ "$output" = "${forwarded}" ]
    [ "$(adds)" -eq 0 ]
}

@test "loading it again and again loads the key once" {
    unset SSH_AUTH_SOCK
    keys id_rsa
    for _ in 1 2 3; do
        run load_snippet
        [ "$status" -eq 0 ]
    done
    [ "$(adds)" -eq 1 ]
}

@test "shells starting together load the key once" {
    unset SSH_AUTH_SOCK
    keys id_rsa
    mkdir -p "$(dirname "${SOCK}")"
    echo dead > "${SOCK}"
    export FAKE_ADD_DELAY=0.2
    pids=()
    for i in 1 2 3 4 5; do
        load_snippet > /dev/null &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do
        wait "${pid}"
    done
    [ "$(starts)" -eq 1 ]
    [ "$(adds)" -eq 1 ]
}

@test "with no identity file the agent is still started, silently" {
    unset SSH_AUTH_SOCK
    run --separate-stderr load_snippet
    [ "$status" -eq 0 ]
    [ "$output" = "${SOCK}" ]
    [ -z "$stderr" ]
    [ "$(adds)" -eq 0 ]
}

@test "loading the key prints nothing" {
    unset SSH_AUTH_SOCK
    keys id_rsa
    run --separate-stderr load_snippet
    [ "$status" -eq 0 ]
    [ "$output" = "${SOCK}" ]
    [ -z "$stderr" ]
    [ "$(adds)" -eq 1 ]
}

# The next tests run the real ssh-agent and ssh-add (ssh -G stays fake, so the
# user's own ~/.ssh/config is not read), on a terminal as a login shell would
# be: a real ssh-add asks for a passphrase on /dev/tty even with stdin closed.
use_real_agent() {
    require ssh-keygen
    require script
    require timeout
    local c real
    for c in ssh-agent ssh-add; do
        real="$(PATH="${PATH#"${FAKEBIN}:"}" command -v "$c")" ||
            skip "$c is not installed"
        ln -sf "${real}" "${FAKEBIN}/$c"
    done
    mkdir -p -m 700 "${HOME}/.ssh"
}

# Source the snippet in a fresh zsh on a pseudo-terminal and print what it
# wrote there. A prompt waiting for a passphrase runs into the timeout.
load_on_tty() {
    timeout 10 script -qec "zsh -f -c 'source ${SNIPPET}' < /dev/null" /dev/null
}

teardown() {
    pkill -f "ssh-agent -a ${SOCK}" 2> /dev/null || true
}

@test "a real agent gets a key without a passphrase" {
    use_real_agent
    unset SSH_AUTH_SOCK
    ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/id_ed25519"
    run load_on_tty
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run env SSH_AUTH_SOCK="${SOCK}" ssh-add -l
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == *"$(ssh-keygen -lf "${HOME}/.ssh/id_ed25519.pub" | cut -d' ' -f2)"* ]]
}

@test "a key with a passphrase is skipped without asking" {
    use_real_agent
    unset SSH_AUTH_SOCK
    ssh-keygen -q -t ed25519 -N 'secret' -f "${HOME}/.ssh/id_ed25519"
    run load_on_tty
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run env SSH_AUTH_SOCK="${SOCK}" ssh-add -l
    [ "$status" -eq 1 ]
}

@test "github.com adds its key to the agent when used" {
    run awk '/^Host /{host=$2} host=="github.com" && $1=="AddKeysToAgent"{print $2}' "${REPO}/sshconfig"
    [ "$status" -eq 0 ]
    [ "$output" = yes ]
}
