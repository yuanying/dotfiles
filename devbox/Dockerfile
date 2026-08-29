# ==============================================================================
# Unified Dockerfile - CPU/CUDA/ROCm
# ==============================================================================
# Build examples:
#   CPU:  make image
#   CUDA: make cuda
#   ROCm: make rocm
#
# Base images are pinned in the Makefile (*_IMAGE variables) and versions of
# the tools below are pinned in ARGs, so that Renovate can update them.
# ==============================================================================

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE} AS base

ENV DEBIAN_FRONTEND=noninteractive

# A toolchain and the headers built against it. No build stage in this file
# uses them any more -- the ones that remain start from their own language
# images -- but they are still reached for at runtime, because user_base builds
# on this stage and so they survive into the final image: asdf-built languages
# and Nvim's tree-sitter parsers compile there. That is why they are not
# repeated in the user list below. Everything else a user reaches for goes in
# user_base instead.
RUN set -x -e && \
    apt-get update && \
    apt-get install -y \
        apt-utils \
        autoconf \
        automake \
        bison \
        build-essential \
        ca-certificates \
        git \
        libncurses-dev \
        pkg-config

# Everything below is for the person using the container, not for the build.
# This stage is pushed on its own (see the Makefile), so it carries the user
# account and the whole package set; main only adds tools that are not apt
# packages.
FROM base AS user_base

RUN set -x -e && \
    apt-get update && \
    apt-get install -y \
        curl \
        dpkg \
        dnsutils \
        file \
        git-lfs \
        iproute2 \
        iputils-ping \
        jq \
        libbz2-dev \
        libc6 \
        libcairo2-dev \
        libffi-dev \
        libgcc-s1 \
        libgdbm-dev \
        libgdbm6 \
        libgl1 \
        libgoogle-perftools-dev \
        libio-socket-ip-perl \
        libjpeg-dev \
        liblzma-dev \
        libopenblas-dev \
        libpng-dev \
        libprotobuf-dev \
        libreadline-dev \
        libsqlite3-dev \
        libssl-dev \
        libssl3 \
        libstdc++6 \
        libtinfo6 \
        libutempter0 \
        libyaml-dev \
        locales \
        net-tools \
        openssh-client \
        openssh-server \
        pciutils \
        qemu-utils \
        rsync \
        software-properties-common \
        strace \
        sudo \
        wget \
        zlib1g \
        zlib1g-dev \
        zsh

ENV LANG="en_US.UTF-8"
ENV LC_ALL="en_US.UTF-8"
ENV LANGUAGE="en_US.UTF-8"

RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
	locale-gen --purge $LANG && \
	dpkg-reconfigure --frontend=noninteractive locales && \
	update-locale LANG=$LANG LC_ALL=$LC_ALL LANGUAGE=$LANGUAGE

RUN mkdir /run/sshd
RUN sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd
RUN sed 's/#Port 22/Port 3222/' -i /etc/ssh/sshd_config

# Create a user
ENV USER=yuanying
RUN set -x -e && \
    (getent group render > /dev/null || groupadd -g 110 render) && \
    (getent group libvirt > /dev/null || groupadd -g 112 libvirt) && \
    (getent group render2 > /dev/null || groupadd -g 993 render2) && \
    (getent group docker > /dev/null || groupadd -g 988 docker) && \
    echo "yuanying:100000:65536" >> /etc/subuid && \
    echo "yuanying:100000:65536" >> /etc/subgid && \
    useradd -G video,render,render2,libvirt,docker,systemd-journal,systemd-network,systemd-timesync -g 50 -m -s /bin/zsh -u 501 "$USER" && \
    echo "$USER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# The two package lists are split by this file on purpose. The list above is
# older than it and still relies on recommends -- less, xauth, gnupg, manpages
# and ncurses-term arrive that way, and nothing requests them by name -- while
# the applications below have never wanted the recommends of podman, virtinst
# and friends. Moving the file changes what is installed, so it stays here.
COPY etc/apt/apt.conf.d/01norecommend /etc/apt/apt.conf.d/01norecommend

RUN set -x -e && \
    apt-get update && \
    apt-get install -y \
	    mosh \
        bat \
        bubblewrap \
        cmake \
        ccache \
        libcurl4-openssl-dev \
        fzf \
        silversearcher-ag \
        ripgrep \
        socat \
        fd-find \
        universal-ctags \
        # frecency ベースのディレクトリジャンプ。herdr-navigator の
        # zoxide ソースもこの履歴を読む
        zoxide \
        # virt
        virtinst \
        libvirt-clients \
        genisoimage \
        uuid-runtime \
        bzip2 \
        kpartx \
        # podman
        podman uidmap slirp4netns \
        # stable-diffusion pytorch
        libomp-dev libjpeg62 \
        unzip && \
    chmod 4755 /usr/bin/bwrap

USER "$USER"
ENV HOME="/home/$USER"

# docker builder
FROM docker:28-cli AS docker_builder

# golang builder
FROM golang:1.27 AS golang_builder
RUN go install golang.org/x/tools/gopls@latest
RUN go install golang.org/x/tools/cmd/goimports@latest
RUN go install github.com/nsf/gocode@latest
RUN go install github.com/x-motemen/ghq@latest
RUN go install github.com/jstemmer/gotags@latest
# renovate: datasource=go depName=github.com/asdf-vm/asdf extractVersion=^v(?<version>.+)$
ARG ASDF_VERSION=0.20.0
RUN go install github.com/asdf-vm/asdf/cmd/asdf@v${ASDF_VERSION}

# node builder
# The bookworm variant is deliberate: its glibc is older than Ubuntu 24.04's, so
# the binaries copied out of this stage keep working in the final image.
FROM node:24.19.0-bookworm AS node_builder

# herdr navigator plugin builder
# Plugins declare their own build commands, and this one is Rust, so it gets a
# stage of its own; herdr_plugin_builder folds the result back in so the main
# stage still copies /opt/herdr/plugins as a single directory. Bookworm for the
# same glibc reason as node_builder.
FROM rust:1.98-bookworm AS herdr_navigator_builder

# renovate: datasource=github-releases depName=thanhdat77/herdr-navigator extractVersion=^v(?<version>.+)$
ARG HERDR_NAVIGATOR_VERSION=0.3.6
# The manifest invokes the binary as ./target/release/herdr-navigator, so the
# crate keeps its build layout. The rest of target/ is intermediate output
# weighing well over a gigabyte and goes away.
RUN git clone --depth 1 --branch v${HERDR_NAVIGATOR_VERSION} \
        https://github.com/thanhdat77/herdr-navigator \
        /opt/herdr/plugins/herdr-navigator && \
    cd /opt/herdr/plugins/herdr-navigator && \
    cargo build --release && \
    find target -mindepth 1 -maxdepth 1 ! -name release -exec rm -rf {} + && \
    find target/release -mindepth 1 -maxdepth 1 ! -name herdr-navigator -exec rm -rf {} + && \
    rm -rf .git

# herdr plugin builder
# One block per plugin, each cloned at a pinned tag and built where it will live
# in the final image: /opt/herdr/plugins/<plugin id>. entrypoint.sh links every
# plugin it finds under that directory, so adding one only means adding a block
# here. The base image is node because most plugins are Node projects; one that
# needs another toolchain builds in its own stage and is copied in below.
FROM node_builder AS herdr_plugin_builder

# Forked from jhochenbaum/herdr-hunk-diff to add `review.branch_scope`, which lets a
# branch review diff the base against the working tree instead of `<base>...HEAD`, so
# uncommitted and untracked files show up. The fork's FORK.md covers how to retire it if
# upstream gains the same setting.
#
# Tags are `v<upstream>-fork.<N>`. The `versioning=regex` makes Renovate read `fork.<N>`
# as a build number; read as a plain semver prerelease it would rank below `v0.1.0` and
# `ignoreUnstable` would drop it. `^v?` because `extractVersion` strips the `v` first.
# The directory name stays `jhochenbaum.hunkdiff` -- that is the plugin id, which
# entrypoint.sh links by and dotfiles binds keys against.
# renovate: datasource=github-releases depName=yuanying/herdr-hunk-diff versioning=regex:^v?(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)-fork\.(?<build>\d+)$ extractVersion=^v(?<version>.+)$
ARG HERDR_HUNK_DIFF_VERSION=0.1.0-fork.1
# This plugin depends on the `hunkdiff` npm package only to get a hunk binary,
# and that package weighs ~500 MB because it ships Bun. Drop it after the build
# and point the path the plugin resolves at the hunk the main stage installs.
RUN git clone --depth 1 --branch v${HERDR_HUNK_DIFF_VERSION} \
        https://github.com/yuanying/herdr-hunk-diff \
        /opt/herdr/plugins/jhochenbaum.hunkdiff && \
    cd /opt/herdr/plugins/jhochenbaum.hunkdiff && \
    npm ci && \
    npm run build && \
    npm uninstall hunkdiff --no-save --omit=dev && \
    ln -sfn /usr/local/bin/hunk node_modules/.bin/hunk && \
    rm -rf .git

# Jump to any workspace, agent, session or directory from one fuzzy picker.
# Built above because it is Rust; this is only where the tree joins the others.
COPY --from=herdr_navigator_builder /opt/herdr/plugins/herdr-navigator /opt/herdr/plugins/herdr-navigator

# main
# Tools that are not apt packages: language toolchains, prebuilt binaries and
# the herdr plugin trees. Anything installable with apt belongs in user_base.
FROM user_base AS main

# golang
COPY --from=golang_builder /usr/local/go /usr/local/go
RUN sudo chown -R $USER:staff /usr/local/go
COPY --from=golang_builder /go/bin /go/bin
RUN sudo chown -R $USER:staff /go/bin
COPY --from=docker_builder /usr/local/libexec/docker/cli-plugins /usr/local/lib/docker/cli-plugins/

# Install go tools
ENV GOPATH="/go"
ENV PATH="$GOPATH/bin:$PATH"

# Set default environment variables
# vi/vim/editor はいずれも update-alternatives で nvim に向けてあるが、
# EDITOR の値をそのまま表示するツールがあるので実体の名前で持つ。
# VISUAL は EDITOR より優先して読むツール向け。entrypoint.sh がこの 2 つを
# sshd の SetEnv へ渡すので、値の定義元はここ 1 箇所だけにする。
ENV EDITOR=nvim
ENV VISUAL=nvim
# nvim は起動時に端末へ背景色を問い合わせ (DSR)、応答が無いとタイムアウトを
# 待って E1568 を出す。mosh や herdr のプラグインペイン越しでは応答が返らない。
# 問い合わせは --cmd や設定ファイルより前に走るので、抑止はこの環境変数しかない。
# 配色は $NVIM_COLORSCHEME で決め termguicolors も明示しているため、
# 問い合わせを止めても background/termguicolors/colorscheme は変わらない。
ENV NVIM_NOTTYFAST=1
ENV GOPATH="$HOME"
ENV GHQ_ROOT="$HOME/src"

# neovim
# renovate: datasource=github-releases depName=neovim/neovim extractVersion=^v(?<version>.+)$
ARG NEOVIM_VERSION=0.12.5
RUN \
     curl -L https://github.com/neovim/neovim/releases/download/v${NEOVIM_VERSION}/nvim-linux-x86_64.tar.gz | sudo sudo tar zx --strip-components 1 -C /usr
RUN \
   sudo update-alternatives --install /usr/bin/vi vi /usr/bin/nvim 60 && \
   sudo update-alternatives --config vi && \
   sudo update-alternatives --install /usr/bin/vim vim /usr/bin/nvim 60 && \
   sudo update-alternatives --config vim && \
   sudo update-alternatives --install /usr/bin/editor editor /usr/bin/nvim 60 && \
   sudo update-alternatives --config editor

# tree-sitter CLI
# nvim-treesitter は main ブランチからパーサーを自前でビルドする。その
# コンパイルとパーサー生成を回すのがこの CLI で、無いと :TSInstall が動かない。
# Mac 側は bin/mac/setup-packages.sh の brew install tree-sitter が担当する。
# renovate: datasource=github-releases depName=tree-sitter/tree-sitter extractVersion=^v(?<version>.+)$
ARG TREE_SITTER_VERSION=0.26.13
RUN \
    curl -fsSL https://github.com/tree-sitter/tree-sitter/releases/download/v${TREE_SITTER_VERSION}/tree-sitter-linux-x64.gz | \
        gunzip | sudo tee /usr/local/bin/tree-sitter > /dev/null && \
    sudo chmod +x /usr/local/bin/tree-sitter

# herdr
# renovate: datasource=github-releases depName=herdrdev/herdr extractVersion=^v(?<version>.+)$
ARG HERDR_VERSION=0.8.2
RUN \
    sudo curl -fsSL -o /usr/local/bin/herdr \
        https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-x86_64 && \
    sudo chmod +x /usr/local/bin/herdr

# hunk
# renovate: datasource=github-releases depName=modem-dev/hunk extractVersion=^v(?<version>.+)$
ARG HUNK_VERSION=0.19.0
RUN \
    sudo mkdir -p /opt/hunk && \
    curl -fsSL https://github.com/modem-dev/hunk/releases/download/v${HUNK_VERSION}/hunkdiff-linux-x64.tar.gz | \
        sudo tar zx --strip-components 1 -C /opt/hunk && \
    sudo ln -s /opt/hunk/hunk /usr/local/bin/hunk

# moshi-hook
# 端末アプリ Moshi (getmoshi.app) との連携デーモン。各エージェントの設定
# ファイルへフックを登録し、127.0.0.1:24543 のゲートウェイと Moshi への
# WebSocket を持つ。ペアリングと起動は runtime 側の仕事で、entrypoint.sh と
# bin/setup.sh が受け持つ。
#
# バイナリは GitHub ではなく自前の CDN で配られていて、最新版は
# /hook/latest/version.txt に置かれている。Renovate はそこを custom
# datasource として読む (renovate.json の customDatasources)。
# ここに置く実体は root 所有なので `moshi-hook update` の自己更新は効かない。
# 版はこの ARG が正で、更新はイメージの作り直しで入る。
# renovate: datasource=custom.moshi-hook depName=moshi-hook extractVersion=^v(?<version>.+)$
ARG MOSHI_HOOK_VERSION=0.3.10
RUN \
    curl -fsSL https://cdn.getmoshi.app/hook/v${MOSHI_HOOK_VERSION}/moshi-hook_Linux_x86_64.tar.gz | \
        sudo tar zx -C /usr/local/bin moshi-hook && \
    sudo chmod +x /usr/local/bin/moshi-hook && \
    sudo ln -s moshi-hook /usr/local/bin/moshi

# node
# asdf-managed versions still win on PATH; this is the fallback the herdr
# plugins below run on.
COPY --from=node_builder /usr/local/bin/node /usr/local/bin/node
COPY --from=node_builder /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=node_builder /usr/local/include/node /usr/local/include/node
# COPY resolves symlinks, so the npm/npx launchers have to be relinked by hand.
RUN \
    sudo ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    sudo ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && \
    sudo ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack

# herdr plugins
# herdr registers plugins under ~/.config/herdr, which the host $HOME mount
# hides, so entrypoint.sh links these trees in at runtime instead.
COPY --from=herdr_plugin_builder /opt/herdr/plugins /opt/herdr/plugins

# docker
COPY --from=docker_builder /usr/local/bin/docker /usr/local/bin/

# The public HTTPS proxy: see proxy/ and docs/adr/0005. The proxy itself is Go
# and is compiled from proxy/proxyd on first start, so the toolchain installed
# above is what builds it and there is no daemon to install here. yq reads the
# declaration file and bats runs the wrapper's tests -- both are wanted in the
# image because that is where the editing happens.

# The Go one. Ubuntu's `yq` package is a different program with a different
# expression language, so it is not a substitute.
# renovate: datasource=github-releases depName=mikefarah/yq extractVersion=^v(?<version>.+)$
ARG YQ_VERSION=4.53.6
RUN \
    sudo curl -fsSL -o /usr/local/bin/yq \
        https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64 && \
    sudo chmod +x /usr/local/bin/yq

# renovate: datasource=github-releases depName=bats-core/bats-core extractVersion=^v(?<version>.+)$
ARG BATS_VERSION=1.14.0
RUN \
    curl -fsSL https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz | \
        tar zx -C /tmp && \
    sudo /tmp/bats-core-${BATS_VERSION}/install.sh /usr/local && \
    rm -rf /tmp/bats-core-${BATS_VERSION}

# kubectx
# renovate: datasource=github-tags depName=ahmetb/kubectx extractVersion=^v(?<version>.+)$
ARG KUBECTX_VERSION=0.11.0
RUN \
    sudo git clone --depth 1 --branch v${KUBECTX_VERSION} https://github.com/ahmetb/kubectx /opt/kubectx && \
    sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx && \
    sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens

COPY entrypoint.sh /bin/entrypoint.sh
RUN sudo chmod +x /bin/entrypoint.sh
CMD ["/bin/entrypoint.sh"]
