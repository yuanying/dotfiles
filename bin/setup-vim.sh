#!/bin/bash

ROOT=$(dirname "${BASH_SOURCE}")
cd ${ROOT}
ROOT=$(pwd)

rm -f ~/.vimrc
ln -s ${ROOT}/../vimrc ~/.vimrc

mkdir -p ~/.config/nvim
cat <<EOF > ~/.config/nvim/init.vim
set runtimepath^=~/.vim runtimepath+=~/.vim/after
let &packpath = &runtimepath

" :tnoremap <Esc> <C-\><C-n>
source ~/.vimrc
EOF
