autoload -Uz add-zsh-hook
case "${OSTYPE}" in
darwin*)
    function auto_ls() {
        command ls -G
    }
    ;;
linux*)
    function auto_ls() {
        command ls --color
    }
    ;;
esac
add-zsh-hook chpwd auto_ls
