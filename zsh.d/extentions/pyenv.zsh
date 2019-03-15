if which pyenv-virtualenv-init > /dev/null; then
    eval "$(pyenv virtualenv-init -)"
    export PATH=/home/dev/.pyenv/shims:${PATH}
fi

