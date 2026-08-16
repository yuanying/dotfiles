# frecency (訪問頻度 + 最近さ) で cd 履歴を覚えて `z <断片>` で飛ぶ。
# herdr-navigator の zoxide ソースも同じ履歴 (`zoxide query -l`) を読むので、
# ここで hook が入っていないと picker のディレクトリ候補が空になる。
# cd は置き換えず、z / zi を足すだけにしておく。
if which zoxide >/dev/null 2>&1; then
    eval "$(zoxide init zsh)"
fi
