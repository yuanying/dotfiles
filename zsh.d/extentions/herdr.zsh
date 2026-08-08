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

# 名前の付いていないタブに、cwd の basename を付ける。
#
# config.toml の prefix+c は `herdr tab create --label` で名前を渡すが、
# セッションやワークスペースの最初のタブは herdr 自身が名前なしで作るため、
# そこだけは素通りしてしまう。herdr にタブの自動リネームは無く、名前なし
# タブのラベルは表示位置の連番になるだけで cwd を見ない。
#
# API はカスタム名の有無を返さない (TabInfo は label と number のみで、
# しかも未命名時の label は number ではなく表示位置) ので、「ラベルが数字
# だけなら未命名」とみなす。prefix+c や prefix+shift+t で付けた名前は
# 数字にならないため、この判定で上書きを避けられる。
herdr_auto_tab_name() {
  [[ -n "$HERDR_TAB_ID" && -S "$HERDR_SOCKET_PATH" ]] || return 0
  (( $+commands[herdr] )) || return 0

  local name=${PWD:t}
  [[ -n "$name" ]] || return 0

  # 応答を読む必要があるので、window_title と違いソケットではなく CLI を使う。
  local info=$(herdr tab get "$HERDR_TAB_ID" 2>/dev/null) || return 0
  local label=${${info##*'"label":"'}%%'"'*}
  [[ "$label" == <-> ]] || return 0

  herdr tab rename "$HERDR_TAB_ID" "$name" >/dev/null 2>&1
}

# ペインのシェルが起動するたびに送る。どのペインからも値は同じなので、
# 2 回目以降は herdr 側で変更なしとして無視される。
if [[ "$HERDR_ENV" == 1 ]]; then
  [[ -n "$HERDR_SESSION" ]] && herdr_window_title "herdr: ${HERDR_SESSION}"
  herdr_auto_tab_name
fi
