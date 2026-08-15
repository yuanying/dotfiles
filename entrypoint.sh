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
sudo /usr/sbin/sshd -D
