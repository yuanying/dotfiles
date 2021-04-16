#!/bin/bash

ROOT=$(dirname "${BASH_SOURCE}")
cd ${ROOT}
ROOT=$(pwd)

ln -s ${ROOT}/../gitconfig ~/.gitconfig
ln -s ${ROOT}/../tmux.conf ~/.tmux.conf
ln -s ${ROOT}/../tmuxline.conf ~/.tmuxline.conf
ln -s ${ROOT}/../bash_aliases ~/.bash_aliases

ln -s ${ROOT}/../sshconfig ~/.ssh/config

ln -s ${ROOT}/tmux-popup.sh ~/bin/tmux-popup.sh

bash ${ROOT}/setup-vim.sh
bash ${ROOT}/setup-zsh.sh
