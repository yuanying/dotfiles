# ホストごとのテーマ選択。zshrc から Spaceship より先に読み込む。
case ${HOST%%.*} in
  aemilia)
    DOTFILES_THEME=crayonponyfish
    AIRLINE_THEME=base16_paraiso
    _dotfiles_host_theme=1
    ;;
  anietta)
    DOTFILES_THEME=gruvbox
    AIRLINE_THEME=base16_gruvbox_dark_medium
    _dotfiles_host_theme=1
    ;;
  augusta)
    DOTFILES_THEME=monalisa
    AIRLINE_THEME=base16_woodland
    _dotfiles_host_theme=1
    ;;
  boucherie)
    DOTFILES_THEME=tokyonight
    AIRLINE_THEME=base16_tomorrow_night
    _dotfiles_host_theme=1
    ;;
  *)
    DOTFILES_THEME=solarized
    AIRLINE_THEME=${AIRLINE_THEME:-solarized}
    _dotfiles_host_theme=0
    ;;
esac

export DOTFILES_THEME AIRLINE_THEME
if (( _dotfiles_host_theme )); then
  NVIM_COLORSCHEME=$DOTFILES_THEME
  CLAUDE_STATUSLINE_THEME=$DOTFILES_THEME
else
  NVIM_COLORSCHEME=${NVIM_COLORSCHEME:-solarized}
  CLAUDE_STATUSLINE_THEME=${CLAUDE_STATUSLINE_THEME:-solarized}
fi
export NVIM_COLORSCHEME CLAUDE_STATUSLINE_THEME
unset _dotfiles_host_theme
