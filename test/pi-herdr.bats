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

# --- remove ---

create_worker() { # [<branch> [<path>]]
    python3 "$WRAPPER" --repo "$SOURCE" --path "${2:-$TASK}" --branch "${1:-worker}" --base "$BASE"
}

@test "remove deletes a clean worktree and keeps its branch" {
    create_worker
    run python3 "$WRAPPER" remove --path "$TASK"
    [ "$status" -eq 0 ]
    [ ! -e "$TASK" ]
    [ ! -e "$(dirname "$TASK")" ]
    ! git -C "$SOURCE" worktree list | grep -q worktrees/worker
    git -C "$SOURCE" show-ref --verify --quiet refs/heads/worker
}

@test "remove keeps the task's other worktrees and their directory" {
    create_worker worker
    create_worker other "${TASK}-other"
    run python3 "$WRAPPER" remove --path "$TASK"
    [ "$status" -eq 0 ]
    [ -d "${TASK}-other" ]
}

@test "remove --delete-branch deletes a merged branch" {
    create_worker
    run python3 "$WRAPPER" remove --path "$TASK" --delete-branch
    [ "$status" -eq 0 ]
    ! git -C "$SOURCE" show-ref --verify --quiet refs/heads/worker
}

@test "remove --delete-branch keeps an unmerged branch and says so" {
    create_worker
    git -C "$TASK" -c user.name=Test -c user.email=test@example.com commit -qm work --allow-empty
    run python3 "$WRAPPER" remove --path "$TASK" --delete-branch
    [ "$status" -eq 0 ]
    [ ! -e "$TASK" ]
    [[ $output == *"kept branch worker"* ]]
    git -C "$SOURCE" show-ref --verify --quiet refs/heads/worker
}

@test "remove refuses a worktree with changes or untracked files" {
    create_worker
    echo x > "$TASK/untracked"
    run python3 "$WRAPPER" remove --path "$TASK"
    [ "$status" -ne 0 ]
    [ -f "$TASK/untracked" ]
}

@test "remove refuses paths outside the task area" {
    create_worker
    for target in "$SOURCE" "$HOME/outside" "$HOME/.local/state/herdr-tasks/../outside/worktrees/worker" "$HOME/.local/state/herdr-tasks/example/notes/worker"; do
        run python3 "$WRAPPER" remove --path "$target"
        [ "$status" -ne 0 ]
    done
    [ -d "$SOURCE/.git" ]
    [ -d "$TASK" ]
}

@test "remove refuses what is not the top of a linked worktree" {
    create_worker
    mkdir -p "$TASK/sub" "$HOME/.local/state/herdr-tasks/example/worktrees/plain"
    touch "$TASK/sub/.keep"
    git -C "$TASK" add sub/.keep
    for target in "$TASK/sub" "$HOME/.local/state/herdr-tasks/example/worktrees/plain"; do
        run python3 "$WRAPPER" remove --path "$target"
        [ "$status" -ne 0 ]
    done
    [ -d "$TASK/sub" ]
}

@test "remove refuses the main repository and symlinks placed in the task area" {
    mkdir -p "$(dirname "$TASK")"
    ln -s "$SOURCE" "$(dirname "$TASK")/main"
    run python3 "$WRAPPER" remove --path "$(dirname "$TASK")/main"
    [ "$status" -ne 0 ]
    git clone -q "$SOURCE" "$(dirname "$TASK")/clone"
    run python3 "$WRAPPER" remove --path "$(dirname "$TASK")/clone"
    [ "$status" -ne 0 ]
    [ -d "$SOURCE/.git" ]
    [ -d "$(dirname "$TASK")/clone/.git" ]
}

# --- fetch, and repositories the sandbox can write ---
#
# pi's sandbox passes the paths it lets the agent write in PI_SANDBOX_WRITABLE.
# A repository whose git directory lies there may carry hooks or config planted
# from inside the sandbox, so the wrapper refuses to run git on it.

with_remote() {
    REMOTE="${BATS_TEST_TMPDIR}/remote.git"
    git clone -q --bare "$SOURCE" "$REMOTE"
    git -C "$SOURCE" remote add origin "$REMOTE"
}

@test "fetch updates origin's refs and takes no other arguments" {
    with_remote
    run python3 "$WRAPPER" fetch --repo "$SOURCE"
    [ "$status" -eq 0 ]
    git -C "$SOURCE" for-each-ref refs/remotes/origin | grep -q .
    run python3 "$WRAPPER" fetch --repo "$SOURCE" --upload-pack=touch
    [ "$status" -ne 0 ]
    run python3 "$WRAPPER" fetch --repo "$SOURCE" origin main
    [ "$status" -ne 0 ]
}

@test "a repository outside the sandbox's writable paths is accepted" {
    with_remote
    export PI_SANDBOX_WRITABLE="[\"$HOME/.local/state/herdr-tasks/example\"]"
    run python3 "$WRAPPER" fetch --repo "$SOURCE"
    [ "$status" -eq 0 ]
    create_worker
    run python3 "$WRAPPER" remove --path "$TASK"
    [ "$status" -eq 0 ]
}

@test "a repository the sandbox can write is refused by every subcommand" {
    FAKE="$HOME/.local/state/herdr-tasks/example/fake"
    git init -q "$FAKE"
    git -C "$FAKE" -c user.name=Test -c user.email=test@example.com commit -qm initial --allow-empty
    git -C "$FAKE" config core.hooksPath "$FAKE/hooks"
    export PI_SANDBOX_WRITABLE="[\"$HOME/.local/state/herdr-tasks/example\"]"
    run python3 "$WRAPPER" fetch --repo "$FAKE"
    [ "$status" -ne 0 ]
    [[ $output == *"writable from the pi sandbox"* ]]
    run python3 "$WRAPPER" --repo "$FAKE" --path "${TASK}2" --branch other --base HEAD
    [ "$status" -ne 0 ]
    [ ! -e "${TASK}2" ]
}

@test "remove refuses a worktree whose .git was pointed at a planted repository" {
    create_worker
    FAKE="$HOME/.local/state/herdr-tasks/example/fake"
    git init -q "$FAKE"
    git -C "$FAKE" -c user.name=Test -c user.email=test@example.com commit -qm initial --allow-empty
    git -C "$FAKE" worktree add -q "${TASK}-planted" -b planted
    cp "${TASK}-planted/.git" "$TASK/.git"
    export PI_SANDBOX_WRITABLE="[\"$HOME/.local/state/herdr-tasks/example\"]"
    run python3 "$WRAPPER" remove --path "$TASK"
    [ "$status" -ne 0 ]
    [[ $output == *"writable from the pi sandbox"* ]]
    [ -d "$TASK" ]
}

@test "a writable path inside the git directory also refuses it" {
    with_remote
    export PI_SANDBOX_WRITABLE="[\"$SOURCE/.git/hooks\"]"
    run python3 "$WRAPPER" fetch --repo "$SOURCE"
    [ "$status" -ne 0 ]
}
