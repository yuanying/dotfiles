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