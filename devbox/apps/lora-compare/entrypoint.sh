#!/usr/bin/env bash
#
# Serves the working directory with nginx on 8080, in the foreground.
#
# The container runs as the devbox user rather than the image's nginx user, so
# nothing under /var/cache/nginx or /run is writable: the config is written
# here, and everything nginx writes goes under TMPDIR with it.

set -euo pipefail

root=${PWD}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/lora-compare.XXXXXX")
conf=${tmp}/nginx.conf

cat > "${conf}" <<CONF
worker_processes auto;
pid ${tmp}/nginx.pid;
error_log /dev/stderr warn;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;
    sendfile on;

    client_body_temp_path ${tmp}/client_body;
    proxy_temp_path ${tmp}/proxy;
    fastcgi_temp_path ${tmp}/fastcgi;
    uwsgi_temp_path ${tmp}/uwsgi;
    scgi_temp_path ${tmp}/scgi;

    server {
        listen 8080;
        root ${root};
        index index.html;

        # macOS leaves .DS_Store and ._* files behind in the directory.
        location ~ /\. {
            return 404;
        }
    }
}
CONF

exec nginx -c "${conf}" -g 'daemon off;'
