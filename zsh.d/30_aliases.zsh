case "${OSTYPE}" in
darwin*)
  alias ls="ls -G"
  alias ll="ls -lhFG"
  alias la="ls -lahFG"
  ;;
linux*)
  alias ls='ls --color'
  alias ll='ls -lhF --color'
  alias la='ls -lahF --color'
  ;;
esac
alias cp='cp -i'
alias rm='rm -i'
alias mv='mv -i'
alias svim='sudo vim'
alias b='bundle'
alias bi='bundle install'
alias bu='bundle update'
alias bl='bundle list'
alias be='bundle exec'
alias bc='bundle console'
if [ -x "`which hub 2>/dev/null`" ]; then
    alias git='hub'
fi
alias g='git'
alias gs='git status -sb'
alias grep='grep --color=auto'
alias k='kubectl'
alias kg='kubectl get'
alias kd='kubectl describe'
alias kc='kubectl create'
alias ka='kubectl apply'
alias kl='kubectl logs'
alias ke='kubectl exec'
alias vi='vim'
alias delete-ds-store='find . -name ".DS_Store" -print -exec rm -r {} ";"'
alias delete-pyc='find . -name "*.pyc" -print -exec rm -r {} ";"'

if [ "$(uname)" = "Linux" ]; then
    alias pbcopy='xsel --clipboard --input'
    alias pbpaste='xsel --clipboard --output'
    alias open='xdg-open'
fi
