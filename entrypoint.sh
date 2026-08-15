#!/bin/bash

set -x

echo "Setup ssh"
mkdir -p ~/.ssh
curl -fsL https://github.com/yuanying.keys > ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys

echo "Setup env"
mkdir -p ~/.zsh
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.zsh/zsh-syntax-highlighting
git clone https://github.com/zsh-users/zsh-autosuggestions ~/.zsh/zsh-autosuggestions
git clone https://github.com/denysdovhan/spaceship-prompt ~/.zsh/spaceship-prompt
cat <<'EOF' > ~/.zsh/spaceship-prompt/spaceship.patch
diff --git a/sections/jobs.zsh b/sections/jobs.zsh
index cce188a..fc00b0f 100644
--- a/sections/jobs.zsh
+++ b/sections/jobs.zsh
@@ -23,7 +23,7 @@ SPACESHIP_JOBS_AMOUNT_THRESHOLD="${SPACESHIP_JOBS_AMOUNT_THRESHOLD=1}"
 spaceship_jobs() {
   [[ $SPACESHIP_JOBS_SHOW == false ]] && return

-  local jobs_amount=${#jobstates}
+  local jobs_amount=$( jobs -d | awk '!/pwd/' | wc -l | tr -d " ")

   [[ $jobs_amount -gt 0 ]] || return

EOF
cd ~/.zsh/spaceship-prompt && ls && git apply spaceship.patch
git clone https://github.com/zdharma-continuum/history-search-multi-word ~/.zsh/history-search-multi-word

mkdir -p ~/.zsh/zsh-completions
sudo ln -sf /opt/kubectx/completion/_kubectx.zsh /usr/local/share/zsh/site-functions/_kubectx
sudo ln -sf /opt/kubectx/completion/_kubens.zsh /usr/local/share/zsh/site-functions/_kubens

mkdir -p ~/.asdf

echo "Clone dotfiles and setup"
git clone https://github.com/yuanying/dotfiles ~/dotfiles
cd ~/dotfiles
git checkout lua
bash ~/dotfiles/bin/setup.sh

echo "Setup herdr plugins"
# The plugin trees are built into the image, but herdr registers plugins under
# ~/.config/herdr, which comes from the host $HOME mount. Link whatever the
# image ships; later image updates are picked up through the path, so a plugin
# only has to be linked once per host.
linked=$(herdr plugin list)
for plugin in /opt/herdr/plugins/*; do
    manifest=${plugin}/herdr-plugin.toml
    [[ -f ${manifest} ]] || continue
    id=$(sed -n 's/^id = "\(.*\)"/\1/p' "${manifest}" | head -1)
    id=${id:-$(basename "${plugin}")}
    if grep -qF "${id}" <<< "${linked}"; then
        echo "herdr plugin ${id} is already linked"
    else
        herdr plugin link "${plugin}" || echo "failed to link herdr plugin ${id}" >&2
    fi
done

echo "Starting sshd..."
# sudo は env_reset で Dockerfile の ENV を捨て、OpenSSH もセッションの環境を
# 作り直すため、そのままでは EDITOR がログインセッションに残らない。zshrc は
# 対話シェルしか読まないので、ログインシェルを経由せずに起動されるプロセス
# (mosh から直接 exec される herdr と、その子として動く hunk) には何も届かない。
# hunk は $EDITOR を直接見て無ければ編集を拒否し、nvim は $NVIM_COLORSCHEME が
# 無いと既定の配色に落ちる。必要なものだけ SetEnv で渡す。
#
# 値の定義元は 1 箇所に保つ。EDITOR/VISUAL は Dockerfile の ENV、ホスト固有の
# 設定は dotfiles の ~/.zshrc.<hostname>。ここには変数名を持たない。
#
# 注意: sshd の引数は ps に出るので、~/.zshrc.<hostname> が export したものは
# そのまま全ユーザーから見える。秘密はこのファイルではなく ~/.zsh_private
# (zshrc が読む、リポジトリ管理外) に置くこと。
SESSION_ENV=("EDITOR=${EDITOR}" "VISUAL=${VISUAL}" "NVIM_NOTTYFAST=${NVIM_NOTTYFAST}")

# ホスト別設定が export した変数をそのまま渡す。zsh 構文なので zsh に読ませ、
# source の前後で export 済みの一覧を比べて、このファイルが足した分だけを拾う。
# env -i で起動するのは、継承した環境変数を差分から追い出すため。
host_zshrc=~/.zshrc.$(hostname -s)
if [[ -f ${host_zshrc} ]]; then
    zsh_clean=(env -i HOME="${HOME}" PATH="${PATH}" zsh -f -c)
    # typeset の出力は値がクォートされうるので、差分からは名前だけを取り出し、
    # 値は名前で引き直す。
    names=$(
        comm -13 \
            <("${zsh_clean[@]}" 'typeset -px' | sort) \
            <("${zsh_clean[@]}" "source ${host_zshrc} 2>/dev/null; typeset -px" | sort) |
        sed -n 's/^export \([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | tr '\n' ' '
    )
    while IFS= read -r kv; do
        [[ -n ${kv} ]] && SESSION_ENV+=("${kv}")
    done < <("${zsh_clean[@]}" "
        source ${host_zshrc} 2>/dev/null
        for k in ${names}; do
            v=\${(P)k}
            # 空白を含む値は SetEnv の書式に載らず、黙って捨てられる。
            [[ -n \${v} && \${v} != *[[:space:]]* ]] && print -r -- \"\${k}=\${v}\"
        done
    ")
fi

# SetEnv は -o を複数回渡しても最初の 1 つしか効かないので、まとめて渡す。
sudo /usr/sbin/sshd -D -o "SetEnv ${SESSION_ENV[*]}"
