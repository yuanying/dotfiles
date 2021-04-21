if [[ -f "${HOME}/.zsh/history-search-multi-word/history-search-multi-word.plugin.zsh" ]]; then
    source "${HOME}/.zsh/history-search-multi-word/history-search-multi-word.plugin.zsh"
else
    function select-history() {
    BUFFER=$(history -n -r 1 | fzf --no-sort +m --query "$LBUFFER" --prompt="History > ")
    CURSOR=$#BUFFER
    }

    zle -N select-history
    bindkey '^R' select-history
fi
