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

brew tap homebrew/cask-fonts
brew install --cask font-hack-nerd-font
