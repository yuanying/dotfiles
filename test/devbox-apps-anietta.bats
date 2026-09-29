#!/usr/bin/env bats

# The compose definition of the apps anietta runs next to its devbox. The same
# properties as boucherie's (devbox-apps.bats) -- proxyd forwards to the
# container names, the containers run as the devbox user with $HOME at the same
# path, and nothing at run time points back into this checkout -- plus what
# llama-server needs on an AMD GPU.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    require yq
    COMPOSE="${REPO}/devbox/apps/compose.anietta.yaml"
    [ -f "${COMPOSE}" ]
}

q() {
    yq -r "explode(.) | $1" "${COMPOSE}"
}

@test "anietta shares the project name with boucherie" {
    [ "$(q '.name')" = "devbox-apps" ]
}

@test "anietta runs llama-server" {
    [ "$(q '.services | keys | join(" ")')" = "llama-server" ]
}

@test "llama-server is named after itself, restarts always and runs as the devbox user" {
    [ "$(q '.services.llama-server.container_name')" = "llama-server" ]
    [ "$(q '.services.llama-server.restart')" = "always" ]
    [ "$(q '.services.llama-server.user')" = "501:50" ]
    [ "$(q '.services.llama-server.init')" = "true" ]
}

@test "llama-server sees \$HOME at the same path as the devbox, and nothing from this checkout" {
    q '.services.llama-server.volumes[]' | grep -qx '/home/yuanying:/home/yuanying'
    run bash -c "yq -r 'explode(.) | .services[].volumes[]' '${COMPOSE}' | grep -v '^/'"
    [ "${status}" -eq 1 ]
}

@test "llama-server is on v6net only, and v6net is made outside compose" {
    [ "$(q '.services.llama-server.networks | keys | join(" ")')" = "v6net" ]
    [ "$(q '.networks | keys | join(" ")')" = "v6net" ]
    [ "$(q '.networks.v6net.external')" = "true" ]
    ! grep -qiE 'ipv6|ip6|sysctl|driver_opts' "${COMPOSE}"
}

@test "llama-server builds from a directory whose image carries its entrypoint" {
    local context="${REPO}/devbox/apps/$(q '.services.llama-server.build.context')"
    [ -f "${context}/Dockerfile" ]
    [ -x "${context}/entrypoint.sh" ]
    grep -q '^COPY entrypoint.sh ' "${context}/Dockerfile"
}

@test "llama-server gets the AMD GPU" {
    q '.services.llama-server.devices[]' | grep -qx '/dev/kfd'
    q '.services.llama-server.devices[]' | grep -qx '/dev/dri'
    [ "$(q '.services.llama-server.group_add | length')" -gt 0 ]
}

@test "llama-server runs the build in the strix llama.cpp checkout" {
    [ "$(q '.services.llama-server.working_dir')" = "/home/yuanying/src/github.com/halo-box/strix-prefill-opt" ]
    [ "$(q '.services.llama-server.environment.LLAMA_SERVER')" = "build-hip-rocm10/bin/llama-server" ]
}

@test "llama-server serves qwen3.8 on every IPv4 interface at 8082" {
    local args
    args=" $(q '.services.llama-server.command | join(" ")') "
    [[ ${args} == *" -m /home/yuanying/models/qwen3.8-flash-next/"*".gguf "* ]]
    [[ ${args} == *" --alias qwen3.8-flash-next "* ]]
    [[ ${args} == *" --host 0.0.0.0 "* ]]
    [[ ${args} == *" --port 8082 "* ]]
}
