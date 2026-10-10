#!/bin/bash
#
# pi coding agent の設定を ~/.pi/agent (PI_CODING_AGENT_DIR があればそこ) へ
# 流し込む。devbox でも Mac でも bin/setup.sh から呼ばれる。
#
# settings.json は pi 自身が (/settings や最後に見せた changelog の版を)、
# web-search.json は pi-web-access が (curator の切り替えを) 書き戻すので、
# symlink にはせず Claude Code の settings.json と同じく jq でマージする。
# 優先順は 手元 < 共通 < ホスト別。

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PI_DIR=${ROOT}/pi
AGENT_DIR=${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}
HOST=$(hostname -s)

mkdir -p "${AGENT_DIR}"

merge_json() { # <ファイル名 (拡張子なし)>
    local target=${AGENT_DIR}/$1.json
    local common=${PI_DIR}/$1.json
    local host=${PI_DIR}/$1.${HOST}.json
    # 該当ホストが無ければ共通ファイルをもう一度重ねる (Claude と同じ落とし方)。
    [[ -f ${host} ]] || host=${common}
    [[ -f ${target} ]] || echo '{}' > "${target}"
    jq -s '.[0] * .[1] * .[2]' "${target}" "${common}" "${host}" \
        > "${target}.tmp" && mv -f "${target}.tmp" "${target}"
}

if ! command -v jq > /dev/null; then
    echo "jq が無いので ${AGENT_DIR} の設定のマージをスキップした" >&2
else
    merge_json settings
    merge_json keybindings
    merge_json web-search
fi

# 自作の extension / テーマ / プロンプトテンプレート。ディレクトリごとではなく
# 1 つずつ張る。extensions/ には herdr と moshi-hook も自分のファイルを置き、
# /settings で作ったテーマなどをリポジトリに混ぜたくないため。extension は
# 単体の .ts でも index.ts を持つディレクトリでもよいので、どちらも張る。
# pi/ から消したものの張り残し (リポジトリを指して切れたリンク) は片付ける。
# 他所を指すリンクは切れていても触らない。
for kind in extensions themes prompts; do
    mkdir -p "${AGENT_DIR}/${kind}"
    for link in "${AGENT_DIR}/${kind}"/*; do
        if [[ -L ${link} && ! -e ${link} && $(readlink "${link}") == "${PI_DIR}/${kind}/"* ]]; then
            rm -f "${link}"
        fi
    done
    for entry in "${PI_DIR}/${kind}"/*; do
        [[ -e ${entry} ]] || continue
        ln -sfn "${entry}" "${AGENT_DIR}/${kind}/$(basename "${entry}")"
    done
done

# ユーザー指示は Claude Code と同じものを使う。pi はエージェントディレクトリの
# CLAUDE.md も読む。~/.claude/CLAUDE.md はホストごとのファイルで dotfiles の
# 管理外なので、あるときだけ張る。pi 用に手で書いた指示があれば触らない。
if [[ -f ${HOME}/.claude/CLAUDE.md ]] && \
        [[ ! -e ${AGENT_DIR}/AGENTS.md ]] && \
        { [[ -L ${AGENT_DIR}/CLAUDE.md ]] || [[ ! -e ${AGENT_DIR}/CLAUDE.md ]]; }; then
    ln -sfn "${HOME}/.claude/CLAUDE.md" "${AGENT_DIR}/CLAUDE.md"
fi

# パッケージ (extension) を入れる。宣言はマージで settings.json に入っているが、
# pi は宣言だけでは入れてくれない (pi update --extensions も未導入のものは
# 入れない)。pi install は冪等で、同じ版なら宣言を増やさず、版が違えば
# 宣言ごと入れ替えるので、リポジトリの宣言を毎回流せばよい。
if ! command -v pi > /dev/null; then
    echo "pi が無いのでパッケージのインストールをスキップした" >&2
elif command -v jq > /dev/null; then
    export PI_CODING_AGENT_DIR=${AGENT_DIR}
    jq -r '.packages[]? | if type == "string" then . else .source end' \
        "${PI_DIR}/settings.json" |
    while read -r source; do
        pi install "${source}" < /dev/null || \
            echo "pi install ${source} に失敗した" >&2
    done
fi
