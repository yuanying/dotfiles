#!/usr/bin/env bats

# bin/merge-toml-config.py pours the keys the repository tracks into a config
# file the tool itself also writes back to. Keys it does not track, and their
# comments, must survive; the result must always stay valid TOML.
#
# Arrays are the tricky case: the tool (or a person) may have spread one over
# several lines, and replacing only the line with the key leaves the rest of
# the old array dangling.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    require python3
    MERGE="${REPO}/bin/merge-toml-config.py"
    TARGET="${BATS_TEST_TMPDIR}/config.toml"
    COMMON="${BATS_TEST_TMPDIR}/common.toml"
    HOST="${BATS_TEST_TMPDIR}/host.toml"
    echo '' > "${HOST}"
}

# Prints the value at a dotted path of the merged file as JSON, failing if the
# file is not valid TOML.
value_of() {
    python3 - "${TARGET}" "$1" <<'PY'
import json, sys, tomllib
with open(sys.argv[1], "rb") as f:
    value = tomllib.load(f)
for part in sys.argv[2].split("."):
    value = value[part]
print(json.dumps(value))
PY
}

@test "a multi-line array in the target is replaced as a whole" {
    cat > "${TARGET}" <<'EOF'
# keep me
model = "local"

[sandbox_workspace_write]

writable_roots = [
    "/old/a",
    "/old/b",
]
network_access = false

[tui]
theme = "old"
EOF
    cat > "${COMMON}" <<'EOF'
[sandbox_workspace_write]
writable_roots = ["/new/a", "/new/b"]
network_access = true
EOF

    run python3 "${MERGE}" "${TARGET}" "${COMMON}" "${HOST}"
    [ "$status" -eq 0 ]

    run value_of sandbox_workspace_write.writable_roots
    [ "$status" -eq 0 ]
    [ "$output" = '["/new/a", "/new/b"]' ]
    run value_of sandbox_workspace_write.network_access
    [ "$output" = 'true' ]
    run value_of model
    [ "$output" = '"local"' ]
    run value_of tui.theme
    [ "$output" = '"old"' ]
    grep -q '^# keep me$' "${TARGET}"
    ! grep -q '/old/' "${TARGET}"
}

@test "brackets inside strings do not end a multi-line array early" {
    cat > "${TARGET}" <<'EOF'
[sandbox_workspace_write]
writable_roots = [
    "/odd]name", # a comment with ] in it
    "/old",
]
EOF
    cat > "${COMMON}" <<'EOF'
[sandbox_workspace_write]
writable_roots = ["/new"]
EOF

    run python3 "${MERGE}" "${TARGET}" "${COMMON}" "${HOST}"
    [ "$status" -eq 0 ]
    run value_of sandbox_workspace_write.writable_roots
    [ "$status" -eq 0 ]
    [ "$output" = '["/new"]' ]
}

@test "a single-line value is still replaced in place" {
    cat > "${TARGET}" <<'EOF'
[tui]
theme = "old"
status_line = ["a", "b"]
EOF
    cat > "${COMMON}" <<'EOF'
[tui]
theme = "new"
EOF

    run python3 "${MERGE}" "${TARGET}" "${COMMON}" "${HOST}"
    [ "$status" -eq 0 ]
    run value_of tui.theme
    [ "$output" = '"new"' ]
    run value_of tui.status_line
    [ "$output" = '["a", "b"]' ]
}

@test "the repository's codex config allows the sandbox to write and reach the network" {
    echo '' > "${TARGET}"
    run python3 "${MERGE}" "${TARGET}" "${REPO}/codex/config.toml" "${REPO}/codex/config.toml"
    [ "$status" -eq 0 ]

    run value_of sandbox_workspace_write.network_access
    [ "$output" = 'true' ]
    run value_of sandbox_workspace_write.writable_roots
    [ "$output" = '["/home/yuanying/src", "/home/yuanying/.cache", "/home/yuanying/.npm", "/home/yuanying/.local/share", "/home/yuanying/.local/state/herdr-tasks"]' ]
}
