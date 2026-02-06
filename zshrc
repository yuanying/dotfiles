# Load zsh extentions
export PATH=/usr/local/go/bin:/usr/local/bin:/go/bin:$PATH

if [[ -d /opt/rocm/bin ]]; then
    export PATH=/opt/rocm/bin:$PATH
fi

if [[ -d /opt/homebrew/bin ]]; then
    export PATH=/opt/homebrew/bin:$PATH
fi

# brew info zsh-completions
fpath=(${HOME}/.zsh/zsh-completions $fpath)

# Load all of zsh config files
for config_file ($ZSH/*.zsh) source $config_file

# rbenv
#export RBENV_ROOT="${HOME}/.rbenv"
if which rbenv > /dev/null; then eval "$(rbenv init -)"; fi

# golang
if [ -x "`which go 2>/dev/null`" ]; then
    export GOPATH=$HOME
    export PATH=$GOPATH/bin:$PATH
    export GO111MODULE=on
fi

## vim in Container
if [[ -f /opt/vim/bin/vim ]]; then
    export PATH=/opt/vim/bin:$PATH
fi

## mosh in Container
if [[ -f /opt/mosh/bin/mosh ]]; then
    export PATH=/opt/mosh/bin:$PATH
fi

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

if [[ -d ~/.asdf ]]; then
    export ASDF_DATA_DIR=~/.asdf
    export PATH=${ASDF_DATA_DIR}/bin:${ASDF_DATA_DIR}/shims:${PATH}
fi

# uniq path
typeset -U path

export PATH=${HOME}/bin:${PATH}

fpath+=~/.zfunc; autoload -Uz compinit; compinit

zstyle ':completion:*' menu select

if [[ -d "$HOME/.local/bin" ]]; then
    export PATH=${HOME}/.local/bin:${PATH}
fi

if [[ -f "$HOME/.local/bin/env" ]]; then
  . "$HOME/.local/bin/env"
fi

# vim: set ft=zsh :
