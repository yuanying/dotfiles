#!/usr/bin/env bats
#
# pi/extensions/sandbox (docs/adr/0013)。判定ロジックは node --test の単体テストで、
# 書き込みとソケットの封じ込めは本物の bubblewrap で確かめる。

load helpers

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    PROJ="${HOME}/proj"
    mkdir -p "${PROJ}"
    git init -q "${PROJ}"
}

require_node_types() {
    require node
    # .ts をそのまま読める (type stripping) 版が要る。
    node -e 'process.exit(process.features.typescript ? 0 : 1)' 2> /dev/null ||
        skip "node cannot run TypeScript directly"
}

require_bwrap() {
    require_node_types
    require bwrap
    bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc true 2> /dev/null ||
        skip "bwrap cannot create a sandbox here"
}

# asdf の shim は $HOME を差し替えると版を決められないので、システムの python を使う。
require_system_python() {
    [[ -x /usr/bin/python3 ]] || skip "/usr/bin/python3 is not installed"
}

sandboxed() { # <command> [<settings JSON>]
    run node "${REPO}/test/pi-sandbox-run.ts" "${PROJ}" "$@"
}

@test "the decision logic passes its unit tests" {
    require_node_types
    run node --test "${REPO}/test/pi-sandbox.test.ts"
    echo "${output}"
    [ "${status}" -eq 0 ]
}

@test "the shared settings are valid" {
    require_node_types
    run node -e '
        const { readSettingsFile } = await import(process.argv[1]);
        readSettingsFile(process.argv[2]);
    ' --input-type=module "${REPO}/pi/extensions/sandbox/policy.ts" "${REPO}/pi/config/sandbox.json"
    echo "${output}"
    [ "${status}" -eq 0 ]
}

@test "writes inside the launch directory succeed" {
    require_bwrap
    sandboxed 'echo ok > inside.txt && cat inside.txt'
    [[ ${output} == *"ok"*"[exit 0]"* ]]
    [ -f "${PROJ}/inside.txt" ]
}

@test "writes outside the launch directory fail" {
    require_bwrap
    sandboxed 'echo x > ~/outside.txt'
    [[ ${output} == *"Read-only file system"* ]]
    [ ! -e "${HOME}/outside.txt" ]
}

@test "configured paths are writable" {
    require_bwrap
    mkdir -p "${HOME}/cache"
    sandboxed 'echo x > ~/cache/entry' '{"allowWrite": ["~/cache"]}'
    [[ ${output} == *"[exit 0]"* ]]
    [ -f "${HOME}/cache/entry" ]
}

@test "git hooks, git config and .pi are read-only" {
    require_bwrap
    mkdir -p "${PROJ}/.pi"
    sandboxed 'echo x > .git/hooks/pre-commit; echo x >> .git/config; echo x > .pi/sandbox.json; mv .git/hooks .git/h2'
    [ "$(grep -c 'Read-only file system' <<< "${output}")" -eq 3 ]
    [[ ${output} == *"Device or resource busy"* ]]
    [ ! -e "${PROJ}/.git/hooks/pre-commit" ]
    [ ! -e "${PROJ}/.pi/sandbox.json" ]
}

@test "renaming .git away and recreating hooks is reported afterwards" {
    require_bwrap
    sandboxed 'mv .git .git2 && mkdir -p .git/hooks && echo x > .git/hooks/post-checkout'
    [[ ${output} == *"[changed ${PROJ}/.git/hooks]"* ]]
}

@test "creating a protected path that did not exist is reported afterwards" {
    require_bwrap
    sandboxed 'mkdir .claude && echo x > .envrc'
    [[ ${output} == *"[changed ${PROJ}/.claude]"* ]]
    [[ ${output} == *"[changed ${PROJ}/.envrc]"* ]]
}

@test "unix sockets cannot be created, other sockets can" {
    require_bwrap
    require_system_python
    sandboxed '/usr/bin/python3 -c "import socket; socket.socket(socket.AF_INET); print(\"inet ok\"); socket.socket(socket.AF_UNIX)"'
    [[ ${output} == *"inet ok"* ]]
    [[ ${output} == *"PermissionError"* ]]
}

@test "allowAllUnixSockets lets unix sockets through and keeps writes confined" {
    require_bwrap
    require_system_python
    sandboxed '/usr/bin/python3 -c "import socket; socket.socket(socket.AF_UNIX); print(\"unix ok\")"; echo x > ~/outside.txt' \
        '{"allowAllUnixSockets": true}'
    [[ ${output} == *"unix ok"* ]]
    [ ! -e "${HOME}/outside.txt" ]
}

@test "a commit in a worktree succeeds while the main repository's hooks stay read-only" {
    require_bwrap
    git -C "${PROJ}" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m initial
    git -C "${PROJ}" worktree add -q "${HOME}/wt" -b wt
    PROJ="${HOME}/wt"
    sandboxed 'git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m inside && echo committed; echo x > "$(git rev-parse --git-common-dir)/hooks/post-commit"'
    [[ ${output} == *"committed"* ]]
    [[ ${output} == *"Read-only file system"* ]]
    [ "$(git -C "${HOME}/wt" log -1 --format=%s)" = inside ]
    [ ! -e "${HOME}/proj/.git/hooks/post-commit" ]
}
