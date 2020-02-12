#!/bin/bash

git clone https://github.com/denysdovhan/spaceship-prompt.git ~/.zsh/spaceship-prompt
mkdir -p ~/.zsh/zsh-completions
ln -sf ~/.zsh/spaceship-prompt/spaceship.zsh ~/.zsh/zsh-completions/prompt_spaceship_setup
