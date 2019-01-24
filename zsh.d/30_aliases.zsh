alias ls='ls --color'
alias ll='ls -lhF --color'
alias la='ls -ahF --color'
alias cp='cp -i'
alias rm='rm -i'
alias mv='mv -i'
alias svim='sudo vim'
alias r='rails'
alias b='bundle'
alias bi='bundle install'
alias bu='bundle update'
alias bl='bundle list'
alias be='bundle exec'
alias bc='bundle console'
alias nb='nodebrew'
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

if [ "$(uname)" = "Linux" ]; then
    alias pbcopy='xsel --clipboard --input'
    alias pbpaste='xsel --clipboard --output'
    alias open='xdg-open'
fi
