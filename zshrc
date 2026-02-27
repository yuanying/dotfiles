# Load zsh extentions
export PATH=/usr/local/go/bin:/usr/local/bin:/go/bin:$PATH

if [[ -d ~/.asdf ]]; then
    export ASDF_DATA_DIR=~/.asdf
    export PATH=${ASDF_DATA_DIR}/bin:${ASDF_DATA_DIR}/shims:${PATH}
fi

if [[ -d "$HOME/.local/bin" ]]; then
    export PATH=${HOME}/.local/bin:${PATH}
fi

if [[ -d /opt/rocm/bin ]]; then
    export PATH=/opt/rocm/bin:$PATH
fi

# golang
if [ -x "`which go 2>/dev/null`" ]; then
    export GOPATH=$HOME
    export PATH=$GOPATH/bin:$PATH
    export GO111MODULE=on
fi

# brew info zsh-completions
fpath=(${HOME}/.zsh/zsh-completions $fpath)

# Load all of zsh config files
for config_file ($ZSH/*.zsh) source $config_file

## .zshrc.local
if [[ -f ~/.zshrc.local ]]; then
    source ~/.zshrc.local
fi
if [[ -f ~/.zshrc.local.sh ]]; then
    bash ~/.zshrc.local.sh
fi

## .zsh_private
if [[ -f ~/.zsh_private ]]; then
    source ~/.zsh_private
fi

# uniq path
typeset -U path

export PATH=${HOME}/.claude/bin:${HOME}/bin:${PATH}

fpath+=~/.zfunc; autoload -Uz compinit; compinit

zstyle ':completion:*' menu select

if [[ -f "$HOME/.local/bin/env" ]]; then
  . "$HOME/.local/bin/env"
fi

# vim: set ft=zsh :
