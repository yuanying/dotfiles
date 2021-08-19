if which kubectl >/dev/null 2>&1; then
  alias k='kubectl'

  ## Completion
  if [[ ! -e "${fpath[1]}/_kubectl" ]]; then
    kubectl completion zsh > "${fpath[1]}/_kubectl"
  fi
  # source <(kubectl completion zsh)
  # complete -o default -F __start_kubectl k

fi

export PATH=~/.krew/bin:$PATH

TMUX_SESSION_NAME=$(tmux display-message -p '#S')
if [[ -e ~/.kube/config.${TMUX_SESSION_NAME} ]]; then
    export KUBECONFIG=~/.kube/config.${TMUX_SESSION_NAME}
fi
