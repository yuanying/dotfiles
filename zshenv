ZSH=$HOME/.zsh.d

if [[ -f "$HOME/.cargo/env" ]]; then
    # export CARGO_HOME="$HOME/.cargo"
    # export RUSTUP_HOME="$HOME/.rustup"
    . "$HOME/.cargo/env"
fi
