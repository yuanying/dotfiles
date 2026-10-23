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
    KYOJIN_MODEL=/home/yuanying/models/qwen3.8-flash-next-exl3-yamz-247ef39b
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

@test "llama-server runs Kyojin from its checkout under ~/opt, with the venv next to it" {
    [ "$(q '.services.llama-server.build.context')" = "kyojin" ]
    [ "$(q '.services.llama-server.working_dir')" = "/home/yuanying/opt/kyojin/src" ]
    [ "$(q '.services.llama-server.environment.EXL3_VENV')" = "/home/yuanying/opt/kyojin/venv" ]
    [ "$(q '.services.llama-server.environment.EXL3_ROCM_SDK')" = "/home/yuanying/opt/kyojin/venv/lib/python3.12/site-packages/_rocm_sdk_devel" ]
}

@test "llama-server's Kyojin image has a name of its own, so the llama.cpp one stays to go back to" {
    [ "$(q '.services.llama-server.image')" = "devbox-apps-kyojin" ]
}

@test "llama-server serves qwen3.8 on every IPv4 interface at 8082" {
    local args
    args=" $(q '.services.llama-server.command | join(" ")') "
    [[ ${args} == *" --model ${KYOJIN_MODEL} "* ]]
    [[ ${args} == *" --model-id qwen3.8-flash-next "* ]]
    [[ ${args} == *" --host 0.0.0.0 "* ]]
    [[ ${args} == *" --port 8082 "* ]]
}

@test "llama-server starts Kyojin as it was measured: 256K shared by two sessions, fp16 cache, mixed drafting" {
    local args
    args=" $(q '.services.llama-server.command | join(" ")') "
    [[ ${args} == *" --ctx 262144 "* ]]
    [[ ${args} == *" --sessions 2 "* ]]
    [[ ${args} == *" --cache-bits 0 "* ]]
    [[ ${args} == *" --draft-policy mix "* ]]
    [[ ${args} == *" --chat-template ${KYOJIN_MODEL}/chat_template.jinja "* ]]
    [[ ${args} == *" --slot-save-path /home/yuanying/.cache/kyojin/slots "* ]]
}

@test "llama-server thinks at the template's own default effort and leaves the reply budget to the free context" {
    local args
    args=" $(q '.services.llama-server.command | join(" ")') "
    [[ ${args} == *" --default-reasoning-effort xhigh "* ]]
    [[ ${args} != *" --default-max-tokens "* ]]
    [[ ${args} != *" --no-thinking "* ]]
}

@test "llama-server applies the pack's uncensor preset and streams the n-gram table from disk" {
    [ "$(q '.services.llama-server.environment.EXL3_ABLIT_RUNTIME')" = "${KYOJIN_MODEL}/uncensor-preset/uncensor_spec.json" ]
    [ "$(q '.services.llama-server.environment.EXL3_NGRAM_STREAM')" = "1" ]
    [[ " $(q '.services.llama-server.command | join(" ")') " != *" --no-uncensor "* ]]
}

@test "llama-server no longer points at the abliterated Lygodactylus pack, which is deleted" {
    ! grep -q 'lygo' "${COMPOSE}"
}

@test "llama-server never reaches for the Hugging Face hub" {
    [ "$(q '.services.llama-server.environment.HF_HUB_OFFLINE')" = "1" ]
    [ "$(q '.services.llama-server.environment.TRANSFORMERS_OFFLINE')" = "1" ]
}
