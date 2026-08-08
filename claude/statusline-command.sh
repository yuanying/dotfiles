#!/usr/bin/env bash

INPUT=$(cat)

# ホストごとの配色。~/.zshrc.<hostname> (dotfiles/zshrc.<hostname>) で選ぶ。
# statusline はテーマトークンの対象外で、Claude Code が渡す JSON にも配色は
# 含まれないため、ここだけは自前でパレットを持つ必要がある。
# 未設定なら solarized。Claude Code の起動時の環境変数を引き継ぐので、
# 値を変えたら Claude Code を起動し直すこと。
case "${CLAUDE_STATUSLINE_THEME:-solarized}" in
  tokyonight)
    C_LOW='79;214;190'    # #4fd6be teal
    C_MID='255;199;119'   # #ffc777 yellow
    C_HIGH='255;117;127'  # #ff757f red
    C_DIM='59;66;97'      # #3b4261
    ;;
  gruvbox)
    C_LOW='142;192;124'   # #8ec07c aqua
    C_MID='250;189;47'    # #fabd2f yellow
    C_HIGH='251;73;52'    # #fb4934 red
    C_DIM='102;92;84'     # #665c54 bg3
    ;;
  *)
    C_LOW='42;161;152'    # #2aa198 cyan
    C_MID='181;137;0'     # #b58900 yellow
    C_HIGH='220;50;47'    # #dc322f red
    C_DIM='88;110;117'    # #586e75 base01
    ;;
esac

get_color() {
  local pct=$1
  if [ "$pct" -lt 50 ]; then
    printf '\033[38;2;%sm' "$C_LOW"
  elif [ "$pct" -lt 80 ]; then
    printf '\033[38;2;%sm' "$C_MID"
  else
    printf '\033[38;2;%sm' "$C_HIGH"
  fi
}

progress_bar() {
  local pct=$1
  local filled=$(( pct / 10 ))
  local bar="" i
  for (( i=0; i<filled; i++ )); do bar="${bar}▰"; done
  for (( i=filled; i<10; i++ )); do bar="${bar}▱"; done
  echo "$bar"
}

format_5h_time() {
  local ts="$1"
  if [ -z "$ts" ] || [ "$ts" = "null" ] || [ "$ts" = "0" ]; then echo "?"; return; fi
  TZ=Asia/Tokyo date -d "@$ts" "+%-I%P" 2>/dev/null || echo "?"
}

format_7d_time() {
  local ts="$1"
  if [ -z "$ts" ] || [ "$ts" = "null" ] || [ "$ts" = "0" ]; then echo "?"; return; fi
  TZ=Asia/Tokyo date -d "@$ts" "+%b %-d at %-I%P" 2>/dev/null || echo "?"
}

MODEL_DISPLAY=$(echo "$INPUT" | jq -r '.model.display_name // "unknown"' 2>/dev/null || echo "unknown")
CONTEXT_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' 2>/dev/null || echo "0")
ADDED=$(echo "$INPUT" | jq -r '.cost.total_lines_added // 0' 2>/dev/null || echo "0")
REMOVED=$(echo "$INPUT" | jq -r '.cost.total_lines_removed // 0' 2>/dev/null || echo "0")
CWD=$(echo "$INPUT" | jq -r '.cwd // "."' 2>/dev/null || echo ".")

BRANCH=$( (cd "$CWD" && git branch --show-current 2>/dev/null) || echo "" )

FIVE_HOUR_PCT=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // 0' | awk '{printf "%d", $1}')
SEVEN_DAY_PCT=$(echo "$INPUT" | jq -r '.rate_limits.seven_day.used_percentage // 0' | awk '{printf "%d", $1}')
FIVE_HOUR_RESET=$(echo "$INPUT" | jq -r '.rate_limits.five_hour.resets_at // ""')
SEVEN_DAY_RESET=$(echo "$INPUT" | jq -r '.rate_limits.seven_day.resets_at // ""')

FIVE_HOUR_RESET_FMT=$(format_5h_time "$FIVE_HOUR_RESET")
SEVEN_DAY_RESET_FMT=$(format_7d_time "$SEVEN_DAY_RESET")

RST='\033[0m'
GRAY="\033[38;2;${C_DIM}m"
C1=$(get_color "$CONTEXT_PCT")
C2=$(get_color "$FIVE_HOUR_PCT")
C3=$(get_color "$SEVEN_DAY_PCT")
BAR2=$(progress_bar "$FIVE_HOUR_PCT")
BAR3=$(progress_bar "$SEVEN_DAY_PCT")
SEP="${GRAY} │ ${RST}"

LINE1="🤖 ${C1}${MODEL_DISPLAY}${RST}${SEP}📊 ${C1}${CONTEXT_PCT}%${RST}${SEP}✏️ +${ADDED}/-${REMOVED}${SEP}🔀 ${BRANCH}"
LINE2="⏱ 5h  ${C2}${BAR2}  ${FIVE_HOUR_PCT}%${RST}  Resets ${FIVE_HOUR_RESET_FMT} (Asia/Tokyo)"
LINE3="📅 7d  ${C3}${BAR3}  ${SEVEN_DAY_PCT}%${RST}  Resets ${SEVEN_DAY_RESET_FMT} (Asia/Tokyo)"

printf "%b\n%b\n%b\n" "$LINE1" "$LINE2" "$LINE3"

