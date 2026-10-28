#!/usr/bin/env bats
#
# bin/merge-claude-settings.jq は ~/.claude/settings.json に共通とホスト別の設定を
# 重ねる。hooks 以外は * のとおり後ろが勝ち、hooks は herdr や moshi-hook が手元に
# 入れたものを消さずに、リポジトリのフックを足す。

load helpers

setup() {
    require jq
    MERGE="${REPO}/bin/merge-claude-settings.jq"
    LOCAL="${BATS_TEST_TMPDIR}/local.json"
    COMMON="${BATS_TEST_TMPDIR}/common.json"
    HOST="${BATS_TEST_TMPDIR}/host.json"
    echo '{}' > "${HOST}"

    # moshi-hook と herdr が入れるフックの形。
    cat > "${LOCAL}" <<'JSON'
{
  "model": "opus",
  "theme": "local",
  "hooks": {
    "PostToolUse": [
      {"matcher": "AskUserQuestion", "hooks": [{"type": "command", "command": "moshi-hook claude-hook", "async": true}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "herdr hook"}]}
    ]
  }
}
JSON
    cat > "${COMMON}" <<'JSON'
{
  "theme": "common",
  "hooks": {
    "PostToolUse": [
      {"matcher": "Write|Edit|MultiEdit", "hooks": [{"type": "command", "command": "~/.claude/hooks/gofmt.sh"}]}
    ]
  }
}
JSON
}

merge() {
    jq -s -f "${MERGE}" "$@"
}

@test "settings other than hooks: later files win, untracked keys stay" {
    echo '{"theme": "host"}' > "${HOST}"
    run merge "${LOCAL}" "${COMMON}" "${HOST}"
    [ "$status" -eq 0 ]
    [ "$(jq -r .theme <<< "$output")" = "host" ]
    [ "$(jq -r .model <<< "$output")" = "opus" ]
}

@test "the repository's hook is added after the ones already there" {
    run merge "${LOCAL}" "${COMMON}" "${HOST}"
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.hooks.PostToolUse[].matcher]' <<< "$output")" = '["AskUserQuestion","Write|Edit|MultiEdit"]' ]
    [ "$(jq -r '.hooks.Stop[0].hooks[0].command' <<< "$output")" = "herdr hook" ]
}

@test "merging again adds nothing" {
    merge "${LOCAL}" "${COMMON}" "${HOST}" > "${BATS_TEST_TMPDIR}/once.json"
    run merge "${BATS_TEST_TMPDIR}/once.json" "${COMMON}" "${HOST}"
    [ "$status" -eq 0 ]
    [ "$(jq -c . <<< "$output")" = "$(jq -c . "${BATS_TEST_TMPDIR}/once.json")" ]
}

@test "the common file given twice, as setup.sh does without a host file, adds the hook once" {
    run merge "${LOCAL}" "${COMMON}" "${COMMON}"
    [ "$status" -eq 0 ]
    [ "$(jq '.hooks.PostToolUse | length' <<< "$output")" -eq 2 ]
}

@test "a hook only the host file has is added too" {
    echo '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "host hook"}]}]}}' > "${HOST}"
    run merge "${LOCAL}" "${COMMON}" "${HOST}"
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.hooks.Stop[].hooks[0].command]' <<< "$output")" = '["herdr hook","host hook"]' ]
}

@test "no hooks anywhere: no hooks key is written" {
    echo '{"theme": "x"}' > "${LOCAL}"
    echo '{"theme": "y"}' > "${COMMON}"
    run merge "${LOCAL}" "${COMMON}" "${HOST}"
    [ "$status" -eq 0 ]
    [ "$(jq -c . <<< "$output")" = '{"theme":"y"}' ]
}

@test "the repository's claude/settings.json merges into an empty file" {
    echo '{}' > "${LOCAL}"
    run merge "${LOCAL}" "${REPO}/claude/settings.json" "${REPO}/claude/settings.json"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.hooks.PostToolUse[0].hooks[0].command' <<< "$output")" = "~/.claude/hooks/gofmt.sh" ]
}
