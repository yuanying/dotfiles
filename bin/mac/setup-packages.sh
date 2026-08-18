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
# hunk 本体。hunkdiff プラグインは npm 側の hunk を同梱するので herdr 越しの
# 利用には不要だが、シェルから直接 hunk を叩く用途があるので単体でも入れる。
brew install hunk
# brew install は導入済みのフォーミュラを更新しないので、herdr と hunk は
# upgrade で最新に追従させる。バージョンは brew の formula が決めるため、
# devbox/Dockerfile のピンとの厳密な一致は求めない運用。
brew upgrade herdr hunk
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
    # plugin list の行にはインストール時の ref が入っている:
    #   - <plugin id> (<名前>) enabled [github:<owner/repo>@v<version>]
    # ここから導入済みバージョンを取り出し、Dockerfile のピンと一致すれば
    # 飛ばす (入れ直すとビルドをやり直すため)。ずれていれば入れ直して追従する。
    herdr_plugins_installed=$(herdr plugin list)
    install_herdr_plugin() { # <owner/repo> <ARG 名> <plugin id>
        local version installed
        version=$(devbox_version "$2") || return
        installed=$(sed -n "s/^- $3 .*@v\\([^]]*\\)\\].*/\\1/p" \
            <<< "${herdr_plugins_installed}")
        if [[ ${installed} == "${version}" ]]; then
            echo "herdr plugin $3 は v${version} 導入済み"
            return
        fi
        if [[ -n ${installed} ]]; then
            # install に upgrade 相当は無いので、一度消してから入れ直す。
            herdr plugin uninstall "$3" || {
                echo "herdr plugin uninstall $3 に失敗した" >&2
                return
            }
        fi
        herdr plugin install "$1" --ref "v${version}" --yes || \
            echo "herdr plugin install $1 に失敗した" >&2
    }

    install_herdr_plugin yuanying/herdr-hunk-diff HERDR_HUNK_DIFF_VERSION jhochenbaum.hunkdiff
    install_herdr_plugin thanhdat77/herdr-navigator HERDR_NAVIGATOR_VERSION herdr-navigator
fi
