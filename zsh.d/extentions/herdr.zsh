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

# シェル起動時に、タブ名を cwd の basename にする。
#
# herdr にタブの自動リネームは無く、名前なしタブのラベルは表示位置の連番に
# なるだけで cwd を見ない。そこで新しいシェルが起動したときに一度だけ
# こちらから付ける。cd のたびには付け直さない (作業中にタブ名が変わり続けると
# 目当てのタブを見失う)。移動先に名前を合わせたいときは ~/bin/herdr-tab-here
# を手で呼ぶ。
#
# 手動で付けた名前 (prefix+shift+t) は残す。tmux が手動 rename-window で
# automatic-rename を切るのと同じ扱いで、自分が最後に付けた名前から変わって
# いたら、以後そのタブには触らない。API はカスタム名の有無を返さない
# (TabInfo は label と number だけで、しかも未命名時の label は number では
# なく表示位置) ため、判定はラベルの文字列比較で行う。
typeset -g _herdr_tab_name=

herdr_auto_tab_name() {
  [[ "$HERDR_ENV" == 1 && -n "$HERDR_TAB_ID" && -S "$HERDR_SOCKET_PATH" ]] || return 0
  (( $+commands[herdr] )) || return 0

  local name=${PWD:t}
  [[ -n "$name" ]] || return 0

  # 応答を読む必要があるので、window_title と違いソケットではなく CLI を使う。
  local info
  info=$(herdr tab get "$HERDR_TAB_ID" 2>/dev/null) || return 0
  local label=${${info##*'"label":"'}%%'"'*}

  # 数字だけなら未命名。自分が付けた名前のままか、既に目的の名前になって
  # いる場合も、引き続き自分の管理下として扱う。
  if [[ "$label" != <-> && "$label" != "$_herdr_tab_name" && "$label" != "$name" ]]; then
    _herdr_tab_name=
    return 0
  fi

  _herdr_tab_name=$name
  [[ "$label" == "$name" ]] && return 0

  herdr tab rename "$HERDR_TAB_ID" "$name" >/dev/null 2>&1
}

# ペインのシェルが起動するたびに送る。どのペインからも値は同じなので、
# 2 回目以降は herdr 側で変更なしとして無視される。
# herdr の外ではウィンドウタイトルもタブ名も不要なので、まとめて
# HERDR_ENV で切り分ける。
if [[ "$HERDR_ENV" == 1 ]]; then
  [[ -n "$HERDR_SESSION" ]] && herdr_window_title "herdr: ${HERDR_SESSION}"

  herdr_auto_tab_name
fi
