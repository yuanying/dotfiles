# llama-server (llama.cpp on ROCm). The image is only a runtime: the build and
# the models are under $HOME, which compose mounts at the same path, so a
# rebuild in the devbox is one restart away.

# The base the devbox itself is built on (ROCM_IMAGE in devbox/Makefile), so
# the ROCm a llama.cpp built in the devbox links against is the one in here,
# and the layers are the ones the host already has.
FROM rocm/dev-ubuntu-24.04:10.0.0-full

# As in devbox/Dockerfile: the ROCm 10 image has no ld.so.conf entry for
# /opt/rocm, and libamdhip64 does not load without one. ggml's CPU backend
# also wants ROCm's libomp, which the devbox finds only through the
# LD_LIBRARY_PATH its shell sets up.
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
