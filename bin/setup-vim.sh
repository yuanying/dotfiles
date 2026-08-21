#!/bin/bash

ROOT=$(dirname "${BASH_SOURCE}")
cd ${ROOT}/..
ROOT=$(pwd)

rm -f ~/.vimrc

mkdir -p ~/.config
rm -rf ~/.config/nvim
ln -s ${ROOT}/nvim ~/.config/nvim

# nvim-treesitter の master ブランチは、lazy が管理するプラグインディレクトリの
# 直下 (parser/ と parser-info/) にビルドしたパーサーを置いていた。main では
# 置き場所が stdpath('data')/site へ移るが、あの残骸は runtimepath に載った
# ままなので、新しいクエリと版が食い違ってハイライトが壊れる。lazy は git
# 管理外のディレクトリを消さないため、ここで落とす。
NVIM_TS_DIR=${XDG_DATA_HOME:-${HOME}/.local/share}/nvim/lazy/nvim-treesitter
for legacy in "${NVIM_TS_DIR}/parser" "${NVIM_TS_DIR}/parser-info"; do
    if [[ -d ${legacy} ]]; then
        echo "nvim-treesitter master 時代の残骸を削除する: ${legacy}"
        rm -rf "${legacy}"
    fi
done
