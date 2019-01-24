#!/bin/bash

ROOT=$(dirname "${BASH_SOURCE}")
cd ${ROOT}
ROOT=$(pwd)

ln -s ${ROOT}/../gitconfig ~/.gitconfig
ln -s ${ROOT}/../tmux.conf ~/.tmux.conf
ln -s ${ROOT}/../bash_aliases ~/.bash_aliases
ln -s ${ROOT}/../zshrc ~/.zshrc
ln -s ${ROOT}/../zshenv ~/.zshenv
ln -s ${ROOT}/../zsh.d ~/.zsh.d
ln -s ${ROOT}/../vimrc ~/.vimrc

ln -s ${ROOT}/../sshconfig ~/.ssh/config

