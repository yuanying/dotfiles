#!/bin/bash

ROOT=$(dirname "${BASH_SOURCE}")
cd ${ROOT}
ROOT=$(pwd)

rm -f ~/.zshrc
rm -f ~/.zshenv
rm -f ~/.zsh.d

ln -s ${ROOT}/../zshrc ~/.zshrc
ln -s ${ROOT}/../zshenv ~/.zshenv
ln -s ${ROOT}/../zsh.d ~/.zsh.d

# ホスト固有の設定。該当ファイルがあるホストだけ symlink を張る。
# zshrc 側は zsh 組み込みの ${HOST%%.*} で同じ名前を組み立てる。
HOST_ZSHRC=${ROOT}/../zshrc.$(hostname -s)
if [[ -f ${HOST_ZSHRC} ]]; then
    ln -sfn ${HOST_ZSHRC} ~/.zshrc.$(hostname -s)
fi