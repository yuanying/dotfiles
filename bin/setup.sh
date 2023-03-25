#!/bin/bash

ROOT=$(dirname "${BASH_SOURCE}")
cd ${ROOT}
ROOT=$(pwd)

ln -s ${ROOT}/../gitconfig ~/.gitconfig
ln -s ${ROOT}/../tmux.conf ~/.tmux.conf
ln -s ${ROOT}/../tmuxline.conf ~/.tmuxline.conf
ln -s ${ROOT}/../bash_aliases ~/.bash_aliases
ln -s ${ROOT}/../spaceshiprc.zsh ~/.spaceshiprc.zsh

ln -s ${ROOT}/../sshconfig ~/.ssh/config

if [[ -f /usr/bin/batcat ]];then
    mkdir -p ~/bin
    ln -s /usr/bin/batcat ~/bin/bat
fi

bash ${ROOT}/setup-vim.sh
bash ${ROOT}/setup-zsh.sh
