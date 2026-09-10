#!/usr/bin/env bats

# The compose definition of the apps boucherie runs next to the devbox. These
# are the properties the rest of the setup relies on: proxyd forwards to the
# container names, the containers write files as the devbox user, the source
# and models are at the same paths as in the devbox, and nothing at run time
# points back into this checkout.

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

@test "the project name is fixed, so any checkout manages the same containers" {
    [ "$(q '.name')" = "devbox-apps" ]
}

@test "boucherie runs sd-webui, sd-viewer and tageditor" {
    [ "$(q '.services | keys | sort | join(" ")')" = "sd-viewer sd-webui tageditor" ]
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

@test "every service sees \$HOME and /mnt at the same paths as the devbox" {
    local s
    for s in $(q '.services | keys | .[]'); do
        q ".services.\"${s}\".volumes[]" | grep -qx '/home/yuanying:/home/yuanying' || { echo "${s}: home"; return 1; }
        q ".services.\"${s}\".volumes[]" | grep -qx '/mnt:/mnt' || { echo "${s}: mnt"; return 1; }
    done
}

@test "nothing is mounted from this checkout" {
    run bash -c "yq -r 'explode(.) | .services[].volumes[]' '${COMPOSE}' 2> /dev/null | grep -v '^/'"
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "every service is on sdnet only, and sdnet is made outside compose" {
    local s
    for s in $(q '.services | keys | .[]'); do
        [ "$(q ".services.\"${s}\".networks | keys | join(\" \")")" = "sdnet" ] || { echo "${s}"; return 1; }
    done
    [ "$(q '.networks.sdnet.external')" = "true" ]
}

@test "every service builds from a directory whose image carries its entrypoint" {
    local s context
    for s in $(q '.services | keys | .[]'); do
        context="${REPO}/devbox/apps/$(q ".services.\"${s}\".build")"
        [ -f "${context}/Dockerfile" ] || { echo "${s}: Dockerfile"; return 1; }
        [ -x "${context}/entrypoint.sh" ] || { echo "${s}: entrypoint"; return 1; }
        grep -q '^COPY entrypoint.sh ' "${context}/Dockerfile" || { echo "${s}: COPY"; return 1; }
    done
}

@test "the services run from their source directories" {
    [ "$(q '.services.sd-webui.working_dir')" = "/home/yuanying/src/github.com/Haoming02/sd-webui-forge-classic" ]
    [ "$(q '.services.sd-viewer.working_dir')" = "/home/yuanying/src/github.com/yuanying/sd-viewer" ]
    [ "$(q '.services.tageditor.working_dir')" = "/home/yuanying/src/github.com/iwaco/tageditor" ]
}

@test "sd-webui gets the GPU" {
    [ "$(q '.services.sd-webui.deploy.resources.reservations.devices[0].driver')" = "nvidia" ]
    [ "$(q '.services.sd-webui.deploy.resources.reservations.devices[0].capabilities | join(" ")')" = "gpu" ]
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
    [ "$(ls "${REPO}"/devbox/apps/*/Dockerfile | wc -l)" -eq 3 ]
    for f in "${REPO}"/devbox/apps/*/Dockerfile; do
        awk '$1 == "FROM" { print $2 }' "${f}" | while read -r image; do
            [[ ${image} == *:* && ${image} != *:latest ]] || { echo "${f}: ${image}"; exit 1; }
        done || return 1
    done
}

@test "renovate reads the apps' Dockerfiles" {
    jq -e '.customManagers[] | select(.managerFilePatterns | index("devbox/apps/*/Dockerfile"))' "${REPO}/renovate.json"
}

@test "sdctl in the boucherie devbox talks to the sd-webui container" {
    grep -qx 'export SDCTL_URL=http://sd-webui:7860' "${REPO}/zshrc.boucherie"
}
