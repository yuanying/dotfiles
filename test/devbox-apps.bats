#!/usr/bin/env bats

# The compose definition of the apps boucherie runs next to the devbox. These
# are the properties the rest of the setup relies on: proxyd forwards to the
# container names, the containers write files as the devbox user, the source
# and models are at the same paths as in the devbox, and nothing at run time
# points back into this checkout.
#
# vmapi is the exception to the mounts and the build: it is a released image,
# and it is root on the host through libvirt, so it sees only what it needs
# (vmapi's docs/adr/0008).

bats_require_minimum_version 1.5.0

load helpers

setup() {
    require yq
    require jq
    COMPOSE="${REPO}/devbox/apps/compose.boucherie.yaml"
    [ -f "${COMPOSE}" ]
}

# q queries the compose file with its YAML anchors and merge keys expanded, the
# way compose itself reads them.
q() {
    yq -r "explode(.) | $1" "${COMPOSE}"
}

# built lists the services whose image is built from a directory next to the
# compose file.
built() {
    q '.services | to_entries | .[] | select(.value.build != null) | .key'
}

@test "the project name is fixed, so any checkout manages the same containers" {
    [ "$(q '.name')" = "devbox-apps" ]
}

@test "boucherie runs sd-webui, sd-viewer, tageditor, lora-compare, lora-datasets and vmapi" {
    [ "$(q '.services | keys | sort | join(" ")')" = "lora-compare lora-datasets sd-viewer sd-webui tageditor vmapi" ]
}

@test "every service is named after itself, restarts always and runs as the devbox user" {
    local s
    for s in $(q '.services | keys | .[]'); do
        [ "$(q ".services.\"${s}\".container_name")" = "${s}" ] || { echo "${s}: name"; return 1; }
        [ "$(q ".services.\"${s}\".restart")" = "always" ] || { echo "${s}: restart"; return 1; }
        [ "$(q ".services.\"${s}\".user")" = "501:50" ] || { echo "${s}: user"; return 1; }
        [ "$(q ".services.\"${s}\".init")" = "true" ] || { echo "${s}: init"; return 1; }
    done
}

@test "every service built here sees \$HOME and /mnt at the same paths as the devbox" {
    local s
    for s in $(built); do
        q ".services.\"${s}\".volumes[]" | grep -qx '/home/yuanying:/home/yuanying' || { echo "${s}: home"; return 1; }
        q ".services.\"${s}\".volumes[]" | grep -qx '/mnt:/mnt' || { echo "${s}: mnt"; return 1; }
    done
}

@test "nothing is mounted from this checkout" {
    run bash -c "yq -r 'explode(.) | .services[].volumes[] | (.source // .)' '${COMPOSE}' 2> /dev/null | grep -v '^/'"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "every service is on v6net only, and v6net is made outside compose" {
    local s
    for s in $(q '.services | keys | .[]'); do
        [ "$(q ".services.\"${s}\".networks | keys | join(\" \")")" = "v6net" ] || { echo "${s}"; return 1; }
    done
    [ "$(q '.networks | keys | join(" ")')" = "v6net" ]
    [ "$(q '.networks.v6net.external')" = "true" ]
}

@test "no service asks for IPv6, so none is reachable around proxyd by it" {
    ! grep -qiE 'ipv6|ip6|sysctl|driver_opts' "${COMPOSE}"
}

@test "every service either builds here or runs a released image" {
    local s
    for s in $(q '.services | keys | .[]'); do
        if [ "$(q ".services.\"${s}\".build")" = "null" ]; then
            [ "${s}" = "vmapi" ] || { echo "${s}"; return 1; }
        fi
    done
}

@test "every service built here builds from a directory whose image carries its entrypoint" {
    local s context
    for s in $(built); do
        context="${REPO}/devbox/apps/$(q ".services.\"${s}\".build.context")"
        [ -f "${context}/Dockerfile" ] || { echo "${s}: Dockerfile"; return 1; }
        [ -x "${context}/entrypoint.sh" ] || { echo "${s}: entrypoint"; return 1; }
        grep -q '^COPY entrypoint.sh ' "${context}/Dockerfile" || { echo "${s}: COPY"; return 1; }
    done
}

@test "every image builds on the default bridge, which reaches the network on a regied host" {
    local s
    for s in $(built); do
        [ "$(q ".services.\"${s}\".build.network")" = "null" ] || { echo "${s}"; return 1; }
    done
}

@test "the services run from their source directories" {
    [ "$(q '.services.sd-webui.working_dir')" = "/home/yuanying/src/github.com/yuanying/sd-webui-forge-neo" ]
    [ "$(q '.services.sd-viewer.working_dir')" = "/home/yuanying/src/github.com/yuanying/sd-viewer" ]
    [ "$(q '.services.tageditor.working_dir')" = "/home/yuanying/src/github.com/iwaco/tageditor" ]
    [ "$(q '.services.lora-compare.working_dir')" = "/home/yuanying/src/github.com/kohya-ss/sd-scripts/outputs/images" ]
    [ "$(q '.services.lora-datasets.working_dir')" = "/home/yuanying/src/github.com/yuanying/lora_datasets" ]
}

@test "sd-webui gets the GPU" {
    [ "$(q '.services.sd-webui.deploy.resources.reservations.devices[0].driver')" = "nvidia" ]
    [ "$(q '.services.sd-webui.deploy.resources.reservations.devices[0].capabilities | join(" ")')" = "gpu" ]
}

@test "sd-webui's image has a C compiler, since Triton builds its CUDA driver module on first use" {
    local packages
    packages=" $(sed -n '/^RUN apt-get/,/rm -rf/p' "${REPO}/devbox/apps/sd-webui/Dockerfile" | tr -s ' \\\n' ' ') "
    [[ ${packages} == *" gcc "* ]]
    [[ ${packages} == *" libc6-dev "* ]]
}

@test "sd-webui listens on every interface with the API and the shared models" {
    local args
    args=" $(q '.services.sd-webui.command | join(" ")') "
    [[ ${args} == *" --listen "* ]]
    [[ ${args} == *" --port 7860 "* ]]
    [[ ${args} == *" --api "* ]]
    [[ ${args} == *" --model-ref /mnt/data/sd-webui/models "* ]]
}

@test "sd-viewer sends to the sd-webui container" {
    [ "$(q '.services.sd-viewer.command | join(" ")')" = "--webui-url http://sd-webui:7860" ]
}

@test "tageditor accepts its public host name" {
    q '.services.tageditor.environment.TAGEDITOR_ALLOWED_HOSTS' | tr ',' '\n' | grep -qx 'tageditor.poissonnerie.dev'
}

@test "no base image floats on latest or goes untagged" {
    local f
    [ "$(ls "${REPO}"/devbox/apps/*/Dockerfile | wc -l)" -eq 8 ]
    for f in "${REPO}"/devbox/apps/*/Dockerfile; do
        awk '$1 == "FROM" { print $2 }' "${f}" | while read -r image; do
            [[ ${image} == *:* && ${image} != *:latest ]] || { echo "${f}: ${image}"; exit 1; }
        done || return 1
    done
}

@test "vmapi runs the released image at a pinned version, which renovate's compose manager follows" {
    [ "$(q '.services.vmapi.build')" = "null" ]
    [[ $(q '.services.vmapi.image') =~ ^ghcr\.io/yuanying/vmapi:v[0-9]+\.[0-9]+\.[0-9]+$ ]]
    # config:recommended reads compose files; nothing here narrows the managers.
    jq -e '.enabledManagers == null' "${REPO}/renovate.json"
    [[ $(basename "${COMPOSE}") =~ ^compose[^/]*\.ya?ml$ ]]
}

@test "vmapi can write to libvirt's socket as the devbox user in the host's libvirt group" {
    [ "$(q '.services.vmapi.user')" = "501:50" ]
    [ "$(q '.services.vmapi.group_add | join(" ")')" = "112" ]
}

@test "vmapi mounts libvirt's sockets, the disk directory at its host path and its settings read only, and nothing else" {
    [ "$(q '[.services.vmapi.volumes[] | .source + ":" + .target + (if .read_only then ":ro" else "" end)] | sort | join(" ")')" = \
        "/home/yuanying/.config/vmapi:/home/yuanying/.config/vmapi:ro /mnt/data/vmapi:/mnt/data/vmapi /var/run/libvirt:/var/run/libvirt" ]
    [ "$(q '[.services.vmapi.volumes[] | .type] | unique | join(" ")')" = "bind" ]
}

@test "vmapi does not start when a mount is missing, rather than have Docker make it owned by root" {
    [ "$(q '[.services.vmapi.volumes[] | .bind.create_host_path] | unique | join(" ")')" = "false" ]
}

@test "vmapi reads the mounted settings" {
    [ "$(q '.services.vmapi.command | join(" ")')" = "--config /home/yuanying/.config/vmapi/config.yaml" ]
}

@test "vmapi publishes no port on the host" {
    [ "$(q '.services.vmapi.ports')" = "null" ]
    [ "$(q '.services.vmapi.network_mode')" = "null" ]
}

@test "proxyd publishes vmapi as vm, behind a login" {
    local services="${REPO}/devbox/proxy/services.boucherie.yaml"
    [ "$(yq -r '.services[] | select(.name == "vm") | .host' "${services}")" = "vmapi" ]
    [ "$(yq -r '.services[] | select(.name == "vm") | .port' "${services}")" = "8080" ]
    [ "$(yq -r '.services[] | select(.name == "vm") | .auth' "${services}")" = "required" ]
    [ "$(yq -r '.services[] | select(.name == "vm") | .viewers.logins | join(" ")' "${services}")" = "yuanying" ]
}

@test "renovate reads the apps' Dockerfiles" {
    jq -e '.customManagers[] | select(.managerFilePatterns | index("devbox/apps/*/Dockerfile"))' "${REPO}/renovate.json"
}

@test "sdctl in the boucherie devbox talks to the sd-webui container" {
    grep -qx 'export SDCTL_URL=http://sd-webui:7860' "${REPO}/zshrc.boucherie"
}
