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
alias delete-ds-store='find . -name "*.DS_Store" -print -exec rm -r {} ";"'
alias delete-pyc='find . -name "*.pyc" -print -exec rm -r {} ";"'

if [ "$(uname)" = "Linux" ]; then
    # pbcopy は bin/pbcopy (OSC 52 でホスト端末へ送る) を setup.sh が
    # ~/bin へ張るので alias は要らない。X も Wayland も無いコンテナでは
    # xsel が動かないため、以前の alias は廃止した。
    # 逆方向 (ホストのクリップボード -> コンテナ) は端末がクリップボード
    # 読み出しを許可しないので pbpaste 相当は用意していない。
    alias open='xdg-open'
fi

function cdd() {
  local -a tmpparent; tmpparent=""
  local -a filename; filename="${1}"
  local -a file
  local -a num; num=0
  while [ $num -le 10 ]; do
    tmpparent="${tmpparent}../"
    file="${tmpparent}${filename}"
    if [ -d "${file}" ] ; then
      cd ${tmpparent}
      break
    fi
    num=$(($num + 1))
  done
}

function cdg() {
  cdd ".git"
}
