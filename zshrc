# Load zsh extentions
export PATH=/usr/local/go/bin:/usr/local/bin:$PATH

if [[ -d /opt/homebrew/bin ]]; then
    export PATH=/opt/homebrew/bin:$PATH
fi

if [[ -f ${HOME}/.asdf/asdf.sh  ]]; then
  . $HOME/.asdf/asdf.sh
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

## Ruby in Container
if [[ -f /opt/ruby/bin/ruby ]]; then
    export PATH=/opt/ruby/bin:$PATH
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

## .zsh_private
if [[ -f ~/.zsh_private ]]; then
    source ~/.zsh_private
fi

# uniq path
typeset -U path

# vim: set ft=zsh :
