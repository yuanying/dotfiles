# for rbenv
# https://github.com/sstephenson/rbenv/
# RBENV_ZSH=$HOME/.rbenv/completions/rbenv.zsh
# if [ -r $RBENV_ZSH ]; then
#     source $RBENV_ZSH
# fi

if [ -x "`which hub 2>/dev/null`" ]; then
    compdef hub=git
fi

# `herdr completion zsh` は #compdef 付きの補完関数を吐き、末尾で自分自身を
# compdef 登録する。compinit より後に読む必要がある (20_modules.zsh で実行済み)。
if [ -x "`which herdr 2>/dev/null`" ]; then
    source <(herdr completion zsh)
fi
