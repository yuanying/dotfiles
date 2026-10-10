# ssh-agent を 1 つだけ立てて、すべての shell で使い回す。
# devbox には systemd が無く agent を立てるものが他に無いので、このままだと
# `ssh -A` で Pod などへ入っても転送する鍵が無い。
#
# - Mac は launchd の agent があるので触らない (Linux のときだけ動く)。
# - SSH_AUTH_SOCK の agent に繋がるなら何もしない。Mac から `ssh -A` で
#   入ったときは、転送されてきた agent を優先する。
# - それ以外は決まったソケットの agent を使う。繋がらなければ (残った古い
#   ソケットは消して) 起動する。agent は shell を閉じても残り、次の shell が
#   同じものを使う。
# - 同時に開いた shell が agent を 2 つ立てないよう、確かめてから起動するまでを
#   ロックで囲む。古いソケットを消す所が競合すると、他の shell が立てた直後の
#   agent のソケットを消してしまうため。
[[ $OSTYPE == linux* ]] || return 0
(( $+commands[ssh-agent] && $+commands[ssh-add] )) || return 0

() {
    # ssh-add -l は 0 (鍵あり)・1 (鍵なし) なら繋がっている。2 は繋がらない。
    if [[ -n $SSH_AUTH_SOCK ]]; then
        ssh-add -l > /dev/null 2>&1
        (( $? <= 1 )) && return
    fi

    local dir=$HOME/.ssh/agent
    local sock=$dir/agent.sock
    local fd

    mkdir -p -m 700 $HOME/.ssh $dir 2> /dev/null || return
    chmod 700 $dir

    SSH_AUTH_SOCK=$sock ssh-add -l > /dev/null 2>&1
    if (( $? > 1 )); then
        # zsystem flock はロックのファイルを作らないので先に作っておく。
        if zmodload -F zsh/system b:zsystem 2> /dev/null && touch $dir/lock; then
            zsystem flock -t 10 -f fd $dir/lock 2> /dev/null
        fi
        SSH_AUTH_SOCK=$sock ssh-add -l > /dev/null 2>&1
        if (( $? > 1 )); then
            rm -f $sock
            ssh-agent -a $sock > /dev/null 2>&1
        fi
        [[ -n $fd ]] && zsystem flock -u $fd
    fi

    SSH_AUTH_SOCK=$sock ssh-add -l > /dev/null 2>&1
    (( $? <= 1 )) && export SSH_AUTH_SOCK=$sock
}
