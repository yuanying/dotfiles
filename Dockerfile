# ==============================================================================
# Unified Dockerfile - CPU/CUDA/ROCm
# ==============================================================================
# Build examples:
#   CPU:  docker build --build-arg BASE_IMAGE=ubuntu:24.04 -t devbox:cpu .
#   CUDA: docker build --build-arg BASE_IMAGE=nvidia/cuda:13.1.0-devel-ubuntu24.04 --network host -t devbox:cuda .
#   ROCm: docker build --build-arg BASE_IMAGE=rocm/dev-ubuntu-24.04:7.0.2-complete -t devbox:rocm .
# ==============================================================================

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE} as base

ENV DEBIAN_FRONTEND=noninteractive

# Install build-essential etc
RUN set -x -e && \
    apt-get update && \
    apt-get install -y \
        apt-utils \
        autoconf \
        automake \
        bison \
        build-essential \
        ca-certificates \
        curl \
        dpkg \
        dnsutils \
        file \
        git \
        git-lfs \
        iproute2 \
        iputils-ping \
        jq \
        libbz2-dev \
        libc6 \
        libcairo2-dev \
        libevent-dev \
        libffi-dev \
        libgcc-s1 \
        libgdbm-dev \
        libgdbm6 \
        libgl1 \
        libgoogle-perftools-dev \
        libio-socket-ip-perl \
        libjpeg-dev \
        liblzma-dev \
        libncurses-dev \
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
        pkg-config \
        qemu-utils \
        rsync \
        software-properties-common \
        strace \
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

COPY etc/apt/apt.conf.d/01norecommend /etc/apt/apt.conf.d/01norecommend

RUN mkdir /run/sshd
RUN sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd
RUN sed 's/#Port 22/Port 3222/' -i /etc/ssh/sshd_config

# Create a user
ENV USER=yuanying
RUN set -x -e && \
    apt-get update && \
    apt-get -y install sudo && \
    (getent group render > /dev/null || groupadd -g 110 render) && \
    (getent group libvirt > /dev/null || groupadd -g 112 libvirt) && \
    (getent group render2 > /dev/null || groupadd -g 993 render2) && \
    (getent group docker > /dev/null || groupadd -g 988 docker) && \
    echo "yuanying:100000:65536" >> /etc/subuid && \
    echo "yuanying:100000:65536" >> /etc/subgid && \
    useradd -G video,render,render2,libvirt,docker,systemd-journal,systemd-network,systemd-timesync -g 50 -m -s /bin/zsh -u 501 "$USER" && \
    echo "$USER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

FROM base as user_base

USER "$USER"
ENV HOME="/home/$USER"

# docker builder
FROM docker:28-cli as docker_builder

# golang builder
FROM golang:1.26 as golang_builder
RUN go install golang.org/x/tools/gopls@latest
RUN go install golang.org/x/tools/cmd/goimports@latest
RUN go install github.com/nsf/gocode@latest
RUN go install github.com/x-motemen/ghq@latest
RUN go install github.com/jstemmer/gotags@latest
RUN go install github.com/asdf-vm/asdf/cmd/asdf@v0.18.0

# tmux builder
FROM base as tmux_builder
RUN git clone https://github.com/tmux/tmux.git && \
    cd tmux && \
    git checkout 3.5a && \
    sh autogen.sh && \
    ./configure && \
    make && \
    mkdir -p /opt/tmux/bin && \
    mv tmux /opt/tmux/bin

# main
FROM user_base as main

# Install user applications
RUN set -x -e && \
    sudo apt-get update && \
    sudo apt-get install -y \
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
        # virt
        virtinst \
        libvirt-clients \
        qemu-utils \
        genisoimage \
        uuid-runtime \
        wget \
        bzip2 \
        kpartx \
        # podman
        podman uidmap slirp4netns \
        # stable-diffusion pytorch
        libomp-dev libjpeg62 \
        unzip && \
    sudo chmod 4755 /usr/bin/bwrap

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
ENV EDITOR=vim
ENV GOPATH="$HOME"
ENV GHQ_ROOT="$HOME/src"

RUN \
     curl -L https://github.com/neovim/neovim/releases/download/v0.11.1/nvim-linux-x86_64.tar.gz | sudo sudo tar zx --strip-components 1 -C /usr
RUN \
   sudo update-alternatives --install /usr/bin/vi vi /usr/bin/nvim 60 && \
   sudo update-alternatives --config vi && \
   sudo update-alternatives --install /usr/bin/vim vim /usr/bin/nvim 60 && \
   sudo update-alternatives --config vim && \
   sudo update-alternatives --install /usr/bin/editor editor /usr/bin/nvim 60 && \
   sudo update-alternatives --config editor

# tmux
COPY --from=tmux_builder /opt/tmux/bin/tmux /usr/local/bin/

# docker
COPY --from=docker_builder /usr/local/bin/docker /usr/local/bin/

RUN \
    sudo git clone https://github.com/ahmetb/kubectx /opt/kubectx && \
    sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx && \
    sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens

COPY entrypoint.sh /bin/entrypoint.sh
RUN sudo chmod +x /bin/entrypoint.sh
CMD ["/bin/entrypoint.sh"]
