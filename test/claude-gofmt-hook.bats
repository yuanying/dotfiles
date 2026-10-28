#!/usr/bin/env bats
#
# claude/hooks/gofmt.sh は Claude Code の PostToolUse フック。Write / Edit で書いた
# .go を gofmt し、整形したときと整形できなかったときは additionalContext で伝える。
# ツールの結果を失敗にすることは無い (いつも exit 0)。

load helpers

setup() {
    require jq
    require gofmt
    HOOK="${REPO}/claude/hooks/gofmt.sh"
    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"
}

# hook <path>: the hook as Claude Code runs it after a Write of <path>.
hook() {
    jq -n --arg path "$1" '{tool_name: "Write", tool_input: {file_path: $path}}' | "${HOOK}"
}

context() {
    jq -r '.hookSpecificOutput.additionalContext' <<< "$output"
}

@test "an unformatted .go file is formatted and the model is told to read it again" {
    printf 'package main\nfunc main(){\nprintln( "x" )\n}\n' > "${WORK}/main.go"
    run hook "${WORK}/main.go"
    [ "$status" -eq 0 ]
    [ "$(jq -r .hookSpecificOutput.hookEventName <<< "$output")" = "PostToolUse" ]
    [[ "$(context)" == "gofmt reformatted ${WORK}/main.go. Read it again"* ]]
    [ -z "$(gofmt -l "${WORK}/main.go")" ]
}

@test "a file already formatted is left alone and nothing is said" {
    printf 'package main\n\nfunc main() {}\n' > "${WORK}/main.go"
    before="$(stat -c %Y "${WORK}/main.go" 2> /dev/null || stat -f %m "${WORK}/main.go")"
    run hook "${WORK}/main.go"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(stat -c %Y "${WORK}/main.go" 2> /dev/null || stat -f %m "${WORK}/main.go")" = "${before}" ]
}

@test "a syntax error is reported, not hidden, and the file is not touched" {
    printf 'package main\nfunc main( {\n' > "${WORK}/main.go"
    cp "${WORK}/main.go" "${WORK}/before.go"
    run hook "${WORK}/main.go"
    [ "$status" -eq 0 ]
    [[ "$(context)" == "gofmt could not format ${WORK}/main.go:"* ]]
    cmp "${WORK}/main.go" "${WORK}/before.go"
}

@test "a file that is not .go is not touched" {
    printf 'a  =  1\n' > "${WORK}/notes.txt"
    run hook "${WORK}/notes.txt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "${WORK}/notes.txt")" = "a  =  1" ]
}

@test "a tool call without a file path is ignored" {
    run bash -c "echo '{\"tool_name\": \"Bash\", \"tool_input\": {\"command\": \"ls\"}}' | '${HOOK}'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "without gofmt on PATH it does nothing" {
    printf 'package main\nfunc main(){}\n' > "${WORK}/main.go"
    # Only what the hook needs besides gofmt, so that a gofmt in /usr/bin is not found either.
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    ln -s "$(command -v jq)" "${BATS_TEST_TMPDIR}/bin/jq"
    ln -s "$(command -v bash)" "${BATS_TEST_TMPDIR}/bin/bash"
    jq -n --arg path "${WORK}/main.go" '{tool_input: {file_path: $path}}' > "${BATS_TEST_TMPDIR}/input.json"
    run env PATH="${BATS_TEST_TMPDIR}/bin" "${HOOK}" < "${BATS_TEST_TMPDIR}/input.json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(sed -n 2p "${WORK}/main.go")" = "func main(){}" ]
}
