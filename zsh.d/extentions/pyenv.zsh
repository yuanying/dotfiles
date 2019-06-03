if which pyenv-virtualenv-init > /dev/null; then
    eval "$(pyenv virtualenv-init -)"
    export PATH=${HOME}/.pyenv/shims:${PATH}
fi

