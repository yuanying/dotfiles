# Kyojin (exllamav3 for Strix Halo) serving Qwen3.8-Flash-Next. The image is
# only a runtime: the engine checkout, its built extension, the venv with the
# ROCm torch and SDK wheels, and the model are under $HOME, which compose
# mounts at the same path.

# The base llama-server's image uses (and the devbox is built on). The venv
# brings its own ROCm, but this is the userland Kyojin was measured with, and
# the layers are the ones the host already has.
FROM rocm/dev-ubuntu-24.04:10.1.0-full

# As in devbox/Dockerfile, so that the libraries resolve as they did in the
# devbox where Kyojin was built and measured.
RUN printf '%s\n' /opt/rocm/lib /opt/rocm/llvm/lib > /etc/ld.so.conf.d/10-rocm.conf && ldconfig

# The devbox user, so that paths under $HOME resolve and files stay theirs.
# GID 50 is staff, which Ubuntu already has.
RUN useradd -u 501 -g 50 -M -d /home/yuanying -s /bin/bash yuanying
ENV HOME=/home/yuanying \
    USER=yuanying

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

USER 501:50
EXPOSE 8082
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
