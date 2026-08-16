#!/bin/bash

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

brew install ripgrep
brew install fd
brew install mosh
brew install tree-sitter
brew install gojq
# statusline-command.sh が jq を呼ぶ。gojq とは別物なので両方入れる。
brew install jq
brew install herdr
# herdr のプラグイン (herdr-navigator など) はインストール時に
# ローカルで cargo build するため Rust ツールチェーンが必要。
brew install rust
# hunk プラグインのビルドが npm を回すので、asdf の node が無いホスト用の
# 保険として入れておく (devbox のイメージが system の node を持っているのと
# 同じ理由。PATH では asdf 側が勝つ)。
brew install node
# frecency でディレクトリを覚える z コマンド。herdr-navigator の
# zoxide ソースがこの履歴を候補に使う。
brew install zoxide

brew tap homebrew/cask-fonts
brew install --cask font-hack-nerd-font

# herdr のプラグイン本体。Linux 側は devbox イメージがビルド済みのツリーを
# 持っていて entrypoint.sh が link するが、Mac にはそれが無いので GitHub から
# 入れる。install はその場でプラグインのビルドコマンド (cargo / npm) を回すの
# で、上の rust と node が要る。
#
# バージョンは devbox/Dockerfile の ARG <NAME>_VERSION を正として読み出す。
# Renovate が追うのはあの ARG だけなので、ここに書き写すと必ず古くなる。
# Mac でもリポジトリごと clone するため、あのファイルは常に手元にある。
# hunk プラグインが upstream ではなく yuanying のフォークなのは devbox と同じ
# 理由 (branch review に未コミット・未追跡ファイルを含めるため)。
DEVBOX_DOCKERFILE=${ROOT}/../../devbox/Dockerfile

# 読めなければプラグインだけ古いバージョンで入る、では困るので落とす。
devbox_version() { # <ARG 名>
    local version
    version=$(sed -n "s/^ARG $1=\\(.*\\)/\\1/p" "${DEVBOX_DOCKERFILE}")
    if [[ -z ${version} ]]; then
        echo "${DEVBOX_DOCKERFILE} から ARG $1 が読めなかった" >&2
        return 1
    fi
    printf '%s' "${version}"
}

if ! command -v herdr > /dev/null; then
    echo "herdr が無いのでプラグインのインストールをスキップした" >&2
else
    # 入れ直すとビルドをやり直すので、既に入っているものは飛ばす。
    herdr_plugins_installed=$(herdr plugin list)
    install_herdr_plugin() { # <owner/repo> <ARG 名> <plugin id>
        local version
        if grep -qF "$3" <<< "${herdr_plugins_installed}"; then
            echo "herdr plugin $3 は導入済み"
            return
        fi
        version=$(devbox_version "$2") || return
        herdr plugin install "$1" --ref "v${version}" --yes || \
            echo "herdr plugin install $1 に失敗した" >&2
    }

    install_herdr_plugin yuanying/herdr-hunk-diff HERDR_HUNK_DIFF_VERSION jhochenbaum.hunkdiff
    install_herdr_plugin thanhdat77/herdr-navigator HERDR_NAVIGATOR_VERSION herdr-navigator
fi
