if which kubectl >/dev/null 2>&1; then
  alias k='kubectl'

  ## Completion
  source <(kubectl completion zsh)
  complete -o default -F __start_kubectl k

fi
