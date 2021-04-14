for script in $(find $(dirname $0)/extentions -maxdepth 2 -type f -name "*.zsh" | sort); do
    source $script
done
