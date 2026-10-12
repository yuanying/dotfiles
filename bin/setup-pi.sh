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
    # Legacy regex denies have no equivalent in pi-automode's tool patterns.
    # Stop before changing package declarations rather than silently drop them.
    legacy=${AGENT_DIR}/config/pi-verdict.json
    # pi-automode 1.17 reads this fixed HOME path, not PI_CODING_AGENT_DIR.
    automode=${HOME}/.pi/agent/extensions/pi-automode/config.json
    if [[ -f ${PI_DIR}/config/pi-automode.json && ! -f ${automode} && -f ${legacy} ]]; then
        if ! jq -e '(.deny // []) | length == 0' "${legacy}" > /dev/null; then
            echo "pi-verdict の deny を手動で移行して ${automode} を作成してから再実行してください" >&2
            exit 1
        fi
    fi

    # Safety configuration is copied, never linked to an agent-editable checkout.
    # Run setup outside pi. Preserve local restrictions and classifier selection.
    if [[ -f ${PI_DIR}/config/pi-automode.json ]]; then
        mkdir -p "$(dirname "${automode}")"
        target=${automode}
        common=${PI_DIR}/config/pi-automode.json
        host=${PI_DIR}/config/pi-automode.${HOST}.json
        [[ -f ${host} ]] || host=${common}
        [[ -f ${target} ]] || echo '{}' > "${target}"
        # Read (but never change) the old policy to retain protected paths.
        # A legacy protected path asked the user; the new glob blocks file tools.
        local_legacy=${legacy}
        [[ -f ${local_legacy} ]] || local_legacy=${target}
        # Bash allow patterns are matched literally (no ~ or $HOME expansion),
        # so absolute script paths are written as __HOME__ and filled in here.
        if ! jq -s --arg home "${HOME}" '
            . as $inputs |
            ($inputs[0] * $inputs[1] * $inputs[2]) |
            .permissions.allow |= (if . then map(split("__HOME__") | join($home)) else . end) |
            .autoMode.deniedPaths = (
                ([$inputs[0:3][].autoMode.deniedPaths[]?] +
                 [$inputs[3].denyPaths[]? | rtrimstr("/") | ., (. + "/*")]) | unique
            ) |
            .permissions.deny = ([$inputs[0:3][].permissions.deny[]?] | unique) |
            .permissions.ask = ([$inputs[0:3][].permissions.ask[]?] | unique) |
            reduce ["soft_deny", "hard_deny", "protectedPaths"][] as $key (.;
                if any($inputs[0:3][]; (.autoMode // {}) | has($key)) then
                    .autoMode[$key] = ([$inputs[0:3][].autoMode[$key][]?] | unique)
                else . end
            )
        ' "${target}" "${common}" "${host}" "${local_legacy}" > "${target}.tmp"; then
            rm -f "${target}.tmp"
            echo "pi-automode 設定のマージに失敗したためパッケージの切り替えを中止した" >&2
            exit 1
        fi
        mv -f "${target}.tmp" "${target}" || exit 1
    fi

    # The sandbox's settings are safety configuration too: copied, not linked,
    # so that a sandboxed agent editing the checkout cannot widen them.
    if [[ -f ${PI_DIR}/config/sandbox.json ]]; then
        mkdir -p "${AGENT_DIR}/extensions"
        target=${AGENT_DIR}/extensions/sandbox.json
        common=${PI_DIR}/config/sandbox.json
        host=${PI_DIR}/config/sandbox.${HOST}.json
        [[ -f ${host} ]] || host=${common}
        [[ -f ${target} ]] || echo '{}' > "${target}"
        jq -s '.[0] * .[1] * .[2]' "${target}" "${common}" "${host}" \
            > "${target}.tmp" && mv -f "${target}.tmp" "${target}"
    fi

    merge_json settings
    merge_json keybindings
    merge_json web-search
    merge_json subscription-usage
fi

# Validates the worktree destination before invoking git; agents use ~/bin.
if [[ -f ${ROOT}/bin/herdr-task-worktree ]]; then
    mkdir -p "${HOME}/bin"
    ln -sfn "${ROOT}/bin/herdr-task-worktree" "${HOME}/bin/herdr-task-worktree"
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

# 依存パッケージを持つ自作の extension (package-lock.json があるもの) に入れる。
# pi はローカルの extension の依存を入れない。lock が入れたものより新しいときだけ
# 入れ直す。
if ! command -v npm > /dev/null; then
    echo "npm が無いので extension の依存のインストールをスキップした" >&2
else
    for lock in "${PI_DIR}"/extensions/*/package-lock.json; do
        [[ -f ${lock} ]] || continue
        dir=$(dirname "${lock}")
        [[ ${dir}/node_modules/.package-lock.json -nt ${lock} ]] && continue
        (cd "${dir}" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund > /dev/null) ||
            echo "${dir} の npm ci に失敗した" >&2
    done
fi

# pi 専用のユーザー指示。手書きのファイルや他所へのリンクは上書きしない。
# 以前の setup が張った Claude Code の指示へのリンクだけは片付ける。
if [[ -L ${AGENT_DIR}/CLAUDE.md && $(readlink "${AGENT_DIR}/CLAUDE.md") == "${HOME}/.claude/CLAUDE.md" ]]; then
    rm -f "${AGENT_DIR}/CLAUDE.md"
fi
if [[ ! -e ${AGENT_DIR}/AGENTS.md && ! -L ${AGENT_DIR}/AGENTS.md ]] || \
        [[ -L ${AGENT_DIR}/AGENTS.md && $(readlink "${AGENT_DIR}/AGENTS.md") == "${PI_DIR}/AGENTS.md" ]]; then
    ln -sfn "${PI_DIR}/AGENTS.md" "${AGENT_DIR}/AGENTS.md"
else
    echo "${AGENT_DIR}/AGENTS.md は既存のユーザー指示なのでリンクをスキップした" >&2
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
