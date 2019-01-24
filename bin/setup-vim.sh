#!/bin/bash

ROOT=$(dirname "${BASH_SOURCE}")
cd ${ROOT}
ROOT=$(pwd)

rm -f ~/.vimrc
ln -s ${ROOT}/../vimrc ~/.vimrc