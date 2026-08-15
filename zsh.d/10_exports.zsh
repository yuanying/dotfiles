# nvim/ に設定一式があるので nvim を本命にするが、コンテナや古いサーバには
# 入っていないことがあるので vim へ落とす。GIT_EDITOR は設定しない
# (git は VISUAL -> EDITOR の順に見るので、このフォールバックがそのまま効く)。
if (( $+commands[nvim] )); then
    export EDITOR=nvim
else
    export EDITOR=vim
fi
# VISUAL は EDITOR より優先して見るツールが多い。片方だけだと挙動がぶれる。
export VISUAL=$EDITOR
# sudoedit 用。sudo は env_reset で環境変数を落とすが、この 3 つは sudoedit が
# 明示的に読む (env_editor が無効な sudoers では sudoers 側の editor が勝つ)。
export SUDO_EDITOR=$EDITOR

# ページャ。PAGER は git や systemctl など「less のオプションを直接渡す」
# 前提のツールから呼ばれるので less のままにし、色付けは man だけに効かせる。
# (bat 公式も PAGER への設定は避けて MANPAGER を使うよう案内している)
export PAGER=less
# -R: 色をそのまま通す / -F: 1 画面に収まるなら即終了 / -i: 検索は
# スマートケース / -M: 位置を出す。-X は alternate screen を殺して man を
# 閉じた後に中身が残るので付けない (less 590 は -F 単体で正しく動く)。
export LESS='-R -F -i -M'
# bat は setup.sh が ~/bin/bat (Debian 系の batcat) へ張るが、~/bin が PATH に
# 入るのは zshrc の後半なのでこの時点では commands に無い。実体を直接見る。
if (( $+commands[bat] )) || [[ -x "${HOME}/bin/bat" ]]; then
    # col(1) を使う定番レシピは util-linux の無いコンテナで動かないので、
    # sed で下線とバックスペース合成を落とす bat 公式版を使う。
    export MANPAGER="sh -c 'sed -u -e \"s/\\x1B\\[[0-9;]*m//g; s/.\\x08//g\" | bat --plain --language man'"
    export MANROFFOPT=-c
fi

export __CF_USER_TEXT_ENCODING='0x1F5:0x08000100:14' # 文字コード設定
#export PATH=$HOME/bin:$HOME/Dropbox/root/bin:$HOME/.nodebrew/current/bin:/usr/local/bin:$PATH
export MANPATH=$HOME/share/man:$MANPATH
# export RBENV_ROOT=/usr/local/var/rbenv #Used Homebrew
export WORDCHARS='*_[]~;!%^(){}<>'
# coreutils
#export PATH=$(brew --prefix coreutils)/libexec/gnubin:$PATH
export MANPATH="/usr/local/opt/coreutils/libexec/gnuman:$MANPATH"
# gnu-sed
export PATH="/usr/local/opt/gnu-sed/libexec/gnubin:$PATH"
export MANPATH="/usr/local/opt/gnu-sed/libexec/gnuman:$MANPATH"
# Homebrew
#export HOMEBREW_NO_ANALYTICS=1
# https://github.com/motemen/ghq
export GHQ_ROOT="${HOME}/src"
