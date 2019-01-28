# Load zsh extentions
export PATH=/usr/local/bin:$PATH

# Load all of zsh config files
for config_file ($ZSH/*.zsh) source $config_file

# rbenv
if which rbenv > /dev/null; then eval "$(rbenv init -)"; fi

# nvm
if which brew >/dev/null 2>&1 &&  ! (brew info nvm | grep "Not installed" >/dev/null 2>&1); then
    source $(brew --prefix nvm)/nvm.sh
elif [[ -s ~/.nvm/nvm.sh ]]; then
    source ~/.nvm/nvm.sh
fi

# golang
if [ -x "`which go 2>/dev/null`" ]; then
    export GOPATH=$HOME
    export PATH=$GOPATH/bin:$PATH
fi

## .zshrc.local
if [[ -f ~/.zshrc.local ]]; then
    source ~/.zshrc.local
fi

# brew info zsh-completions
fpath=(/usr/local/share/zsh-completions $fpath)

# uniq path
typeset -U path

# vim: set ft=zsh :
