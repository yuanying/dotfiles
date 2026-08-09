if which kubectl >/dev/null 2>&1; then
  alias k='kubectl'

  ## Completion
  # 以前は fpath へ書き出していたが、compinit (20_modules.zsh) より後に走るので
  # 生成した初回のシェルでは効かず、kubectl を更新しても古いままだった。
  # herdr と同じく毎回生成する (asdf の shim 込みで 25ms 程度)。
  source <(kubectl completion zsh)
  # complete -o default -F __start_kubectl k

fi

export PATH=~/.krew/bin:$PATH

# TMUX_SESSION_NAME=$(tmux display-message -p '#S')
# if [[ -e ~/.kube/config.${TMUX_SESSION_NAME} ]]; then
#     export KUBECONFIG=~/.kube/config.${TMUX_SESSION_NAME}
# fi
