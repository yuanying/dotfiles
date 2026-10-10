#!/usr/bin/env bats

load helpers

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "$HOME"
    unset PI_CODING_AGENT_DIR
    WRAPPER="${REPO}/bin/herdr-task-worktree"
    TASK="$HOME/.local/state/herdr-tasks/example/worktrees/worker"
    SOURCE="${BATS_TEST_TMPDIR}/source"
    git init -q "$SOURCE"
    git -C "$SOURCE" -c user.name=Test -c user.email=test@example.com commit -qm initial --allow-empty
    BASE=$(git -C "$SOURCE" rev-parse HEAD)
}

@test "herdr rules allow single commands but not shell execution or destructive operations" {
    run node "${REPO}/test/pi-herdr-rules.mjs"
    [ "$status" -eq 0 ]
}

@test "worktree wrapper creates a new branch under the task directory" {
    run python3 "$WRAPPER" --repo "$SOURCE" --path "$TASK" --branch worker --base "$BASE"
    [ "$status" -eq 0 ]
    [ "$(git -C "$TASK" branch --show-current)" = worker ]
    [ "$(git -C "$TASK" rev-parse HEAD)" = "$BASE" ]
}

@test "worktree wrapper rejects outside paths and traversal" {
    for target in "$HOME/outside" "$HOME/.local/state/herdr-tasks/../outside/worktrees/worker" "$HOME/.local/state/herdr-tasks/example/notes/worker"; do
        run python3 "$WRAPPER" --repo "$SOURCE" --path "$target" --branch worker --base "$BASE"
        [ "$status" -ne 0 ]
        [ ! -e "$target" ]
    done
    ! git -C "$SOURCE" show-ref --verify --quiet refs/heads/worker
}

@test "worktree wrapper rejects symlink escapes including a symlinked root" {
    mkdir -p "$(dirname "$TASK")" "$HOME/outside"
    ln -s "$HOME/outside" "$(dirname "$TASK")/escape"
    run python3 "$WRAPPER" --repo "$SOURCE" --path "$(dirname "$TASK")/escape/worker" --branch worker --base "$BASE"
    [ "$status" -ne 0 ]
    rm "$(dirname "$TASK")/escape"
    mv "$HOME/.local/state/herdr-tasks" "$HOME/tasks"
    ln -s "$HOME/tasks" "$HOME/.local/state/herdr-tasks"
    run python3 "$WRAPPER" --repo "$SOURCE" --path "$TASK" --branch worker --base "$BASE"
    [ "$status" -ne 0 ]
}

@test "worktree wrapper rejects existing targets and option injection" {
    mkdir -p "$TASK"
    run python3 "$WRAPPER" --repo "$SOURCE" --path "$TASK" --branch worker --base "$BASE"
    [ "$status" -ne 0 ]
    run python3 "$WRAPPER" --repo "$SOURCE" --path "${TASK}2" --branch worker --base=--help
    [ "$status" -ne 0 ]
    run python3 "$WRAPPER" --repo "$SOURCE" --path "${TASK}2" --branch worker --base "$BASE" --force
    [ "$status" -ne 0 ]
}

@test "setup copies permission policy preserving local protections and host precedence" {
    require jq
    export HOME="${BATS_TEST_TMPDIR}/home.test+[user]"
    mkdir -p "$HOME"
    FAKE="${BATS_TEST_TMPDIR}/checkout"
    mkdir -p "$FAKE/bin" "$FAKE/pi/config" "$HOME/.pi/agent/config" "${BATS_TEST_TMPDIR}/bin"
    cp "${REPO}/bin/setup-pi.sh" "$WRAPPER" "$FAKE/bin/"
    cp "${REPO}/pi/"*.json "$FAKE/pi/"
    cp "${REPO}/pi/config/pi-verdict.json" "$FAKE/pi/config/"
    printf '#!/bin/sh\nexit 0\n' > "${BATS_TEST_TMPDIR}/bin/pi"
    printf '#!/bin/sh\necho testhost\n' > "${BATS_TEST_TMPDIR}/bin/hostname"
    chmod +x "${BATS_TEST_TMPDIR}/bin/"*
    export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
    echo '{"allow":["old"],"deny":["local-deny"],"denyPaths":["~/private"],"ignoreTools":["todo"],"audit":true}' > "$HOME/.pi/agent/config/pi-verdict.json"
    echo '{"classifierModel":"test/model","deny":["host-deny"]}' > "$FAKE/pi/config/pi-verdict.testhost.json"
    run bash "$FAKE/bin/setup-pi.sh"
    [ "$status" -eq 0 ]
    target="$HOME/.pi/agent/config/pi-verdict.json"
    [ ! -L "$target" ]
    jq -e '.audit and .builtinDenyFloor and .classifierModel == "test/model" and (.allow | index("old") | not) and (.deny | index("local-deny") != null) and (.deny | index("host-deny") != null) and (.denyPaths | index("~/private") != null) and (.denyPaths | index("~/.ssh/") != null)' "$target"
    jq -e '.ignoreTools == ["todo", "web_enable"]' "$target"
    [ -x "$HOME/bin/herdr-task-worktree" ]
    run node "${REPO}/test/pi-herdr-rules.mjs" "$target"
    [ "$status" -eq 0 ]
    cp "$target" "${BATS_TEST_TMPDIR}/before.json"
    run bash "$FAKE/bin/setup-pi.sh"
    [ "$status" -eq 0 ]
    cmp "$target" "${BATS_TEST_TMPDIR}/before.json"
}
