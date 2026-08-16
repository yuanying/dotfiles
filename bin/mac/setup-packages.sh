#!/bin/bash

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
# ref は devbox の Dockerfile の ARG <NAME>_VERSION と揃えること。Renovate が
# 追うのは devbox 側だけなので、あちらが上がったらここも手で追随する。
# hunk プラグインが upstream ではなく yuanying のフォークなのも devbox と同じ
# 理由 (branch review に未コミット・未追跡ファイルを含めるため)。
if ! command -v herdr > /dev/null; then
    echo "herdr が無いのでプラグインのインストールをスキップした" >&2
else
    # 入れ直すとビルドをやり直すので、既に入っているものは飛ばす。
    herdr_plugins_installed=$(herdr plugin list)
    install_herdr_plugin() { # <owner/repo> <ref> <plugin id>
        if grep -qF "$3" <<< "${herdr_plugins_installed}"; then
            echo "herdr plugin $3 は導入済み"
        else
            herdr plugin install "$1" --ref "$2" --yes || \
                echo "herdr plugin install $1 に失敗した" >&2
        fi
    }

    install_herdr_plugin yuanying/herdr-hunk-diff v0.1.0-fork.1 jhochenbaum.hunkdiff
    install_herdr_plugin thanhdat77/herdr-navigator v0.3.6 herdr-navigator
fi
