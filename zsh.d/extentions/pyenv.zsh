if which pyenv-virtualenv-init > /dev/null; then eval "$(pyenv virtualenv-init -)"; fi
if which pyenv-virtualenv-init > /dev/null; then
    export PYENV_ROOT="${HOME}/.pyenv"
    eval "$(pyenv init -)"
    export PATH=${HOME}/.pyenv/shims:${PATH}
fi

