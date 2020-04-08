if [[ -d "${HOME}/.pyenv" ]]; then
    export PATH=${HOME}/.pyenv/bin:${HOME}/.pyenv/shims:${PATH}
    export PYENV_ROOT="${HOME}/.pyenv"
    eval "$(pyenv init -)"
fi

