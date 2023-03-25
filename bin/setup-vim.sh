#!/bin/bash

ROOT=$(dirname "${BASH_SOURCE}")
cd ${ROOT}/..
ROOT=$(pwd)

rm -f ~/.vimrc

mkdir -p ~/.config
rm -rf ~/.config/nvim
ln -s ${ROOT}/nvim ~/.config/nvim
