export GOPATH="/go"

export PATH="$GOPATH/bin:/opt/mosh/bin:$PATH"

# Set default environment variables
# zsh.d/10_exports.zsh と揃える。nvim が無い環境では vim へ落とす。
if command -v nvim >/dev/null 2>&1; then
    export EDITOR=nvim
else
    export EDITOR=vim
fi
export VISUAL="$EDITOR"
export SUDO_EDITOR="$EDITOR"
export GOPATH="$HOME"
export GHQ_ROOT="$HOME/src"
