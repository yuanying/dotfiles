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
