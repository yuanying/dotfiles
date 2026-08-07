# herdr のセッション名を、外側ターミナルのウィンドウタイトルに出す。
#
# herdr の画面内にはセッション名を表示する場所がないので、socket API の
# client.window_title.set でホスト側のタイトルを書き換える。この API に
# 対応する CLI サブコマンドはないため、ソケットへ直接 JSON を送る。
# zsh/net/socket を使うので nc や python には依存しない。
herdr_window_title() {
  local title="$1"
  [[ -n "$title" && -S "$HERDR_SOCKET_PATH" ]] || return 0
  zmodload zsh/net/socket 2>/dev/null || return 0
  zsocket "$HERDR_SOCKET_PATH" 2>/dev/null || return 0

  # 応答は読まずに切断する。herdr が応答しなくてもシェルの起動を止めない。
  local fd=$REPLY
  print -r -- "{\"id\":\"zsh:window_title\",\"method\":\"client.window_title.set\",\"params\":{\"title\":\"${title//\"/\\\"}\"}}" >&$fd
  exec {fd}>&-
}

# ペインのシェルが起動するたびに送る。どのペインからも値は同じなので、
# 2 回目以降は herdr 側で変更なしとして無視される。
if [[ "$HERDR_ENV" == 1 && -n "$HERDR_SESSION" ]]; then
  herdr_window_title "herdr: ${HERDR_SESSION}"
fi
