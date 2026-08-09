# Load zsh extentions
export PATH=/usr/local/go/bin:/usr/local/bin:/go/bin:$PATH

if [[ -d ~/.asdf ]]; then
    export ASDF_DATA_DIR=~/.asdf
    export PATH=${ASDF_DATA_DIR}/bin:${ASDF_DATA_DIR}/shims:${PATH}
fi

if [[ -d "$HOME/.local/bin" ]]; then
    export PATH=${HOME}/.local/bin:${PATH}
fi

if [[ -d /opt/rocm/bin ]]; then
    export PATH=/opt/rocm/bin:$PATH
fi

# golang
if [ -x "`which go 2>/dev/null`" ]; then
    export GOPATH=$HOME
    export PATH=$GOPATH/bin:$PATH
    export GO111MODULE=on
fi

# 補完関数の置き場。compinit は zsh.d/20_modules.zsh で 1 回だけ走るので、
# fpath への追加はそれより前 (= この設定ファイル群を読む前) に済ませておく。
# brew info zsh-completions
fpath=(${HOME}/.zsh/zsh-completions ${HOME}/.zfunc $fpath)

# Load all of zsh config files
for config_file ($ZSH/*.zsh) source $config_file

## .zshrc.local (後方互換)
# ホスト固有の設定は dotfiles 管理の .zshrc.<hostname> へ移したが、
# 既存マシンのために従来のファイルも読み続ける。
if [[ -f ~/.zshrc.local ]]; then
    source ~/.zshrc.local
fi
if [[ -f ~/.zshrc.local.sh ]]; then
    bash ~/.zshrc.local.sh
fi

## .zshrc.<hostname> (dotfiles/zshrc.<hostname> から symlink)
# zsh は HOSTNAME を設定しないので、組み込みの HOST から短いホスト名を作る。
# bin/setup-zsh.sh が使う `hostname -s` と同じ値になる。
# .zshrc.local より後に読むので、移行途中で両方に同じ変数があってもこちらが勝つ。
if [[ -f ~/.zshrc.${HOST%%.*} ]]; then
    source ~/.zshrc.${HOST%%.*}
fi

## テーマのフォールバック
# .zshrc.<hostname> が無い (または設定していない) マシンのデフォルトは
# solarized。ホスト別ファイルは上で先に読まれるので、そちらの値が勝つ。
export NVIM_COLORSCHEME=${NVIM_COLORSCHEME:-solarized}
export AIRLINE_THEME=${AIRLINE_THEME:-solarized}
export CLAUDE_STATUSLINE_THEME=${CLAUDE_STATUSLINE_THEME:-solarized}

## .zsh_private
if [[ -f ~/.zsh_private ]]; then
    source ~/.zsh_private
fi

# uniq path
typeset -U path

export PATH=${HOME}/.claude/bin:${HOME}/bin:${PATH}

zstyle ':completion:*' menu select

if [[ -f "$HOME/.local/bin/env" ]]; then
  . "$HOME/.local/bin/env"
fi

# bun
if [[ -d "${HOME}/.bun" ]]; then
    export BUN_INSTALL="${HOME}/.bun"
    if [[ -d "${BUN_INSTALL}/bin" ]]; then
        export PATH=${BUN_INSTALL}/bin:${PATH}
    fi
    # bun completions
    if [[ -s "${BUN_INSTALL}/_bun" ]]; then
        source "${BUN_INSTALL}/_bun"
    fi
fi

# hipfire
if [[ -d "${HOME}/.hipfire/bin" ]]; then
    export PATH=${HOME}/.hipfire/bin:${PATH}
fi

# opencode
if [[ -d "${HOME}/.opencode/bin" ]]; then
    export PATH=${HOME}/.opencode/bin:${PATH}
fi

# antigravity
if [[ -d "${HOME}/.antigravity/antigravity/bin" ]]; then
    export PATH=${HOME}/.antigravity/antigravity/bin:${PATH}
fi

# vim: set ft=zsh :
