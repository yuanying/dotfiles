# Setup fzf
# ---------
if [[ -f "${HOME}/.vim/plugged/fzf/bin/fzf" ]]; then
    if [[ ! "$PATH" == *${HOME}/.vim/plugged/fzf/bin* ]]; then
        export PATH="${PATH:+${PATH}:}${HOME}/.vim/plugged/fzf/bin"
    fi

    # Auto-completion
    # ---------------
    [[ $- == *i* ]] && source "${HOME}/.vim/plugged/fzf/shell/completion.zsh" 2> /dev/null

    # Key bindings
    # ------------
    source "${HOME}/.vim/plugged/fzf/shell/key-bindings.zsh"

    if which ag  >/dev/null 2>&1; then
         export FZF_DEFAULT_COMMAND='ag --nocolor -g ""'
         export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
         export FZF_ALT_C_COMMAND="$FZF_DEFAULT_COMMAND"
         export FZF_DEFAULT_OPTS='
         --color fg:242,bg:236,hl:65,fg+:15,bg+:239,hl+:108
         --color info:108,prompt:109,spinner:108,pointer:168,marker:168
         '
    fi
fi
