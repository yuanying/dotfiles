# lora-compare: static pages comparing LoRA versions, written by sd-scripts'
# outputs/compare/build.py. The image is only nginx; the pages are the
# directory compose mounts from $HOME and sets as the working directory.

FROM nginxinc/nginx-unprivileged:1.31-alpine

USER root
# bash for the entrypoint, as in the other apps.
RUN apk add --no-cache bash
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# The devbox user, so that $HOME, which is not world readable, can be read.
# The image's own nginx user cannot.
USER 501:50
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
