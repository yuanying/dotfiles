#!/bin/bash

ROOT=$(dirname "${BASH_SOURCE}")
cd ${ROOT}
ROOT=$(pwd)

ln -s ${ROOT}/../gitconfig ~/.gitconfig
ln -s ${ROOT}/../tmux.conf ~/.tmux.conf
ln -s ${ROOT}/../tmuxline.conf ~/.tmuxline.conf
ln -s ${ROOT}/../bash_aliases ~/.bash_aliases
ln -s ${ROOT}/../spaceshiprc.zsh ~/.spaceshiprc.zsh

# herdr は設定ファイルを 1 本しか読まず include も無いので、ホストごとに
# 完全な設定を置いて symlink を張り分ける。該当ファイルが無いホストは
# 共通の config.toml へ落とす。
mkdir -p ~/.config/herdr
HERDR_CONFIG=${ROOT}/../herdr/config.$(hostname -s).toml
if [[ ! -f ${HERDR_CONFIG} ]]; then
    HERDR_CONFIG=${ROOT}/../herdr/config.toml
fi
ln -sfn ${HERDR_CONFIG} ~/.config/herdr/config.toml

# Claude Code のカスタムテーマ。どのホストでも両方選べるように全部張る。
# 実際にどれを使うかは各ホストの ~/.claude/settings.json の theme で決める
# (このファイルは machine local で dotfiles 管理外)。
# ディレクトリごとではなくファイル単位で張るのは、/theme で作ったテーマが
# リポジトリに混ざらないようにするため。
mkdir -p ~/.claude/themes
for theme in ${ROOT}/../claude/themes/*.json; do
    ln -sfn ${theme} ~/.claude/themes/$(basename ${theme})
done

if ! grep github.com ~/.ssh/known_hosts > /dev/null; then
cat <<EOF > ~/.ssh/known_hosts
# github.com:22 SSH-2.0-babeld-439edbdb
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
# github.com:22 SSH-2.0-babeld-439edbdb
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
# github.com:22 SSH-2.0-babeld-439edbdb
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
# github.com:22 SSH-2.0-babeld-439edbdb
# github.com:22 SSH-2.0-babeld-439edbdb
EOF
fi

ln -s ${ROOT}/../sshconfig ~/.ssh/config

if [[ -f /usr/bin/batcat ]];then
    mkdir -p ~/bin
    ln -s /usr/bin/batcat ~/bin/bat
fi

bash ${ROOT}/setup-vim.sh
bash ${ROOT}/setup-zsh.sh
