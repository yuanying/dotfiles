# http://qiita.com/ysk_1031/items/8cde9ce8b4d0870a129d

function gcd () {
    local selected_dir=$(ghq list |fzf --preview "bat --color=always --style=header,grid --line-range :80 $(ghq root)/{}/README.*")
    if [ -n "$selected_dir" ]; then
        BUFFER="cd $(ghq root)/${selected_dir}"
        zle accept-line
    fi
    zle clear-screen
}

zle -N gcd
bindkey '^]' gcd
