autoload -Uz colors && colors

COLOR_FG="%F{081}"
COLOR_FG_FAIL="%F{197}"

local ret_status="%(?:${COLOR_FG}# :${COLOR_FG_FAIL}# )"
PROMPT="${ret_status} %F{228}%c%f \$(vcs_info_msg) %f"
#RPROMPT='%{$fg[blue]%}($ZSH_KUBECTL_PROMPT)%{$reset_color%}'
setopt transient_rprompt
