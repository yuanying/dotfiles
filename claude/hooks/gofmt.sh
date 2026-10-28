#!/usr/bin/env bash
#
# Claude Code の PostToolUse フック。Write / Edit で .go のファイルを書いたら
# gofmt をかける。pi では pi/extensions/gofmt.ts が同じことをする。
#
# 整形するとファイルの中身が、モデルが覚えている中身とずれるので、整形したときは
# additionalContext でそう伝えて読み直させる。構文エラーで整形できなかったときも
# gofmt のメッセージを伝える。どちらでもツールの結果は失敗にしない。
# jq か gofmt が無いホストでは何もしない。

set -uo pipefail

command -v jq > /dev/null && command -v gofmt > /dev/null || exit 0

path="$(jq -r '.tool_input.file_path // empty')"
[[ "${path}" == *.go && -f "${path}" ]] || exit 0

if ! listed="$(gofmt -l "${path}" 2>&1)"; then
    context="gofmt could not format ${path}:
${listed}"
elif [[ -z "${listed}" ]]; then
    exit 0
elif ! gofmt -w "${path}"; then
    exit 0
else
    context="gofmt reformatted ${path}. Read it again before editing it."
fi

jq -n --arg context "${context}" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $context}}'
