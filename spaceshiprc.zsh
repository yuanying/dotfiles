SPACESHIP_PROMPT_ORDER=(
  time          # Time stampts section
  user          # Username section
  dir           # Current directory section
  git           # Git section (git_branch + git_status)
  node          # Node.js section
  ruby          # Ruby section
  python        # Python section
  golang        # Go section
  rust          # Rust section
  haskell       # Haskell Stack section
  julia         # Julia section
  docker        # Docker section
  venv          # virtualenv section
  kubectl       # Kubectl context section
  terraform     # Terraform workspace section
  exec_time     # Execution time
  line_sep      # Line break
  jobs          # Background jobs indicator
  exit_code     # Exit code section
  char          # Prompt character
)

SPACESHIP_HOST_SHOW=false
SPACESHIP_USER_SHOW=needed
SPACESHIP_GOLANG_SHOW=false
SPACESHIP_KUBECTL_SHOW=true
SPACESHIP_KUBECTL_VERSION_SHOW=false
SPACESHIP_DOCKER_SHOW=false
SPACESHIP_GCLOUD_SHOW=false
SPACESHIP_JOBS_SHOW=true

# ホストから選んだテーマのパレットを使う。色は truecolor で指定する。
_spaceship_theme_dir=${${(%):-%x}:A:h}/themes/spaceship
source "$_spaceship_theme_dir/${DOTFILES_THEME:-solarized}.zsh"
unset _spaceship_theme_dir

SPACESHIP_TIME_COLOR=$_spaceship_muted
SPACESHIP_USER_COLOR=$_spaceship_warning
SPACESHIP_DIR_COLOR=$_spaceship_accent
SPACESHIP_GIT_BRANCH_COLOR=$_spaceship_secondary
SPACESHIP_GIT_STATUS_COLOR=$_spaceship_error
SPACESHIP_NODE_COLOR=$_spaceship_success
SPACESHIP_RUBY_COLOR=$_spaceship_error
SPACESHIP_PYTHON_COLOR=$_spaceship_warning
SPACESHIP_GOLANG_COLOR=$_spaceship_info
SPACESHIP_RUST_COLOR=$_spaceship_error
SPACESHIP_HASKELL_COLOR=$_spaceship_secondary
SPACESHIP_JULIA_COLOR=$_spaceship_success
SPACESHIP_DOCKER_COLOR=$_spaceship_info
SPACESHIP_VENV_COLOR=$_spaceship_secondary
SPACESHIP_KUBECTL_CONTEXT_COLOR=$_spaceship_info
SPACESHIP_KUBECTL_CONTEXT_COLOR_GROUPS=(
  $_spaceship_error   '\(.+-system)$'
  $_spaceship_warning '\(zlab.+)$'
  $_spaceship_success '.+'
)
SPACESHIP_TERRAFORM_COLOR=$_spaceship_secondary
SPACESHIP_EXEC_TIME_COLOR=$_spaceship_warning
SPACESHIP_JOBS_COLOR=$_spaceship_info
SPACESHIP_EXIT_CODE_COLOR=$_spaceship_error
SPACESHIP_CHAR_COLOR_SUCCESS=$_spaceship_success
SPACESHIP_CHAR_COLOR_FAILURE=$_spaceship_error
SPACESHIP_CHAR_COLOR_SECONDARY=$_spaceship_warning

unset _spaceship_accent _spaceship_secondary _spaceship_info _spaceship_muted
unset _spaceship_success _spaceship_warning _spaceship_error

