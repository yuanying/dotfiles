autoload -Uz colors && colors

# COLOR_FG="%F{081}"
# COLOR_FG_FAIL="%F{197}"
# 
# local ret_status="%(?:${COLOR_FG}$ :${COLOR_FG_FAIL}$ )"
# PROMPT='%F{228}%~%f $(vcs_info_msg)$(kube_ps1)
# ${ret_status}%f'
# #RPROMPT='%{$fg[blue]%}($ZSH_KUBECTL_PROMPT)%{$reset_color%}'
# setopt transient_rprompt

autoload -U promptinit; promptinit
prompt spaceship

SPACESHIP_HOST_SHOW=false
SPACESHIP_USER_SHOW=needed
SPACESHIP_GOLANG_SHOW=false
SPACESHIP_KUBECTL_SHOW=true
SPACESHIP_KUBECTL_VERSION_SHOW=false
SPACESHIP_KUBECONTEXT_COLOR_GROUPS=(
  # red if namespace is "kube-system"
  red    '\(.+-system)$'
  yellow '\(zlab.+)$'
  green '.+'
)
SPACESHIP_DOCKER_SHOW=false
