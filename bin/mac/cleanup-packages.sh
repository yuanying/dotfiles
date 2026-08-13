#!/bin/bash

# setup-packages.sh の逆。過去に入れたが今は要らなくなったものを消す。
# インストール側と違って取り残しは各 Mac に残り続けるため、どのホストで
# 何回流しても同じ結果になるようにしてある。既に無いものは黙って飛ばし、
# 実際に消したものだけを報告する。

set -u

changed=0

note() {
    echo "$1"
    changed=1
}

remove_file() {
    # 壊れた symlink も拾えるように -L を見る。
    [[ -e "$1" || -L "$1" ]] || return 0
    rm -f "$1" && note "削除した: $1"
}

# --- notify_server (2026-08 撤去) ---
# terminal-notifier を叩くだけの常駐 HTTP サーバ。リポジトリ内に呼び出し側が
# 無いまま 0.0.0.0:8989 を開き続けていたので廃止した。KeepAlive が true な
# ので、実体を消す前に launchd から降ろさないと再起動を繰り返す。
NOTIFY_LABEL=com.local.notify

if launchctl list ${NOTIFY_LABEL} > /dev/null 2>&1; then
    # bootout はラベル指定なので plist が先に消えていても効く。古い macOS
    # 向けに remove へ落とす。
    if launchctl bootout gui/$(id -u)/${NOTIFY_LABEL} 2> /dev/null ||
        launchctl remove ${NOTIFY_LABEL} 2> /dev/null; then
        note "launchd から降ろした: ${NOTIFY_LABEL}"
    else
        echo "${NOTIFY_LABEL} を launchd から降ろせなかった" >&2
    fi
fi

remove_file "${HOME}/Library/LaunchAgents/${NOTIFY_LABEL}.plist"
remove_file "${HOME}/bin/notify_server.py"

# plist の StandardOutPath / NOTIFY_LOG が吐いていたログ。
remove_file "${HOME}/notify.log"
remove_file /tmp/notify.stdout.log
remove_file /tmp/notify.stderr.log

# terminal-notifier に依存していたのは notify_server だけなので一緒に落とす。
# 他の formula が依存していれば brew 自身が拒否するため、消えなくてよい。
if command -v brew > /dev/null && brew list --formula terminal-notifier > /dev/null 2>&1; then
    if brew uninstall terminal-notifier; then
        note "brew uninstall した: terminal-notifier"
    else
        note "terminal-notifier を消せなかった (他の formula が依存している?)"
    fi
fi

if [[ ${changed} -eq 0 ]]; then
    echo "消すものは無かった"
fi
