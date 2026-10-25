# Strata (Niko1221/Strata) serving Qwen3.8-Flash-Next. The image is only a
# runtime: the engine checkout with its build and venv, the ROCm it was built
# with (AMD TheRock 7.14.1 for gfx1151) and the model are under $HOME, which
# compose mounts at the same path.

# kyojin's base, whose layers the host already has. The engine does not use
# its ROCm: the entrypoint puts the one under $HOME first.
FROM rocm/dev-ubuntu-24.04:10.1.0-full

# The devbox user, so that paths under $HOME resolve and files stay theirs.
# GID 50 is staff, which Ubuntu already has.
RUN useradd -u 501 -g 50 -M -d /home/yuanying -s /bin/bash yuanying
ENV HOME=/home/yuanying \
    USER=yuanying

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

USER 501:50
EXPOSE 8082
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
