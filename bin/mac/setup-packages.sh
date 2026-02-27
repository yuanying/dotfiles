#!/bin/bash

ROOT=$(dirname "${BASH_SOURCE}")
cd ${ROOT}/../..
ROOT=$(pwd)

brew install ripgrep
brew install fd
brew install terminal-notifier
brew install mosh
brew install tree-sitter
brew install gojq

brew tap homebrew/cask-fonts
brew install --cask font-hack-nerd-font

rm -f ~/bin/notify_server.py
cp -rp ${ROOT}/bin/notify_server.py ~/bin/notify_server.py

if [[ ! -f ~/Library/LaunchAgents/com.local.notify.plist ]]; then
    cp -rp ${ROOT}/LaunchAgents/com.local.notify.plist \
      ~/Library/LaunchAgents/com.local.notify.plist
    chmod +x ~/Library/LaunchAgents/com.local.notify.plist
    launchctl load -w ~/Library/LaunchAgents/com.local.notify.plist
fi
