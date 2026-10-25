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
    STRATA=/home/yuanying/src/github.com/Niko1221/Strata
    GGUF=/home/yuanying/models/qwen3.8-flash-next/Qwen3.8-Flash-Next-Uncensored.i1-IQ4_XS.gguf
    PACK=/home/yuanying/models/strata-packs/orca-mradermacher-i1-iq4_xs
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

@test "llama-server runs Strata from its checkout, with the ROCm it was built with" {
    [ "$(q '.services.llama-server.build.context')" = "strata" ]
    [ "$(q '.services.llama-server.environment.STRATA_ROOT')" = "${STRATA}" ]
    [ "$(q '.services.llama-server.environment.STRATA_SDK')" = "/home/yuanying/opt/strata-rocm/install" ]
    [ "$(q '.services.llama-server.environment.STRATA_HIPBLASLT_TUNING')" = "${STRATA}/tools/hip/gfx1151-hipblaslt-100401.txt" ]
}

@test "llama-server's Strata image has a name of its own, so the Kyojin and llama.cpp ones stay to go back to" {
    [ "$(q '.services.llama-server.image')" = "devbox-apps-strata" ]
}

@test "llama-server serves qwen3.8 under its usual name from the IQ4_XS GGUF and its pack" {
    local args
    args=" $(q '.services.llama-server.command | join(" ")') "
    [ "$(q '.services.llama-server.environment.STRATA_MODEL_NAME')" = "qwen3.8-flash-next" ]
    [ "$(q '.services.llama-server.environment.STRATA_TOKENIZER')" = "${PACK}/tokenizer" ]
    [[ ${args} == *" --pack ${PACK} "* ]]
    [[ ${args} == *" --native ${GGUF} "* ]]
    [[ ${args} == *" --ple-gguf ${GGUF} "* ]]
    [ "$(q '.services.llama-server.environment.STRATA_VISION_MODEL')" = "${GGUF}" ]
}

@test "llama-server answers to the name proxyd passes and the one the devbox uses" {
    [ "$(q '.services.llama-server.environment.STRATA_ALLOWED_HOSTS')" = "qwen38.oeilvert.dev,llama-server" ]
}

@test "llama-server keeps every expert in the GPU's cache, as measured, at the model's full context" {
    local args
    args=" $(q '.services.llama-server.command | join(" ")') "
    [[ ${args} == *" --expert-cache 24576 --mmap-experts "* ]]
    [[ ${args} == *" --max-context 262144 "* ]]
    [[ ${args} == *" --kv int8 "* ]]
    [[ ${args} == *" --prefill 16384 "* ]]
    [[ ${args} == *" --spec 4 "* && ${args} == *" --lookup-chain 3 "* && ${args} == *" --mtp-q4 all "* ]]
    [[ ${args} == *" --mtp-window 8192 "* ]]
    for k in STRATA_PF_FUSED STRATA_IGPU_PROMPT_SET STRATA_PF_F16 STRATA_SH_STREAM STRATA_REFILL_PARTS; do
        [ "$(q ".services.llama-server.environment.${k}")" = "1" ]
    done
}

@test "llama-server no longer points at the abliterated Lygodactylus pack, which is deleted" {
    ! grep -q 'lygo' "${COMPOSE}"
}

@test "llama-server never reaches for the Hugging Face hub" {
    [ "$(q '.services.llama-server.environment.HF_HUB_OFFLINE')" = "1" ]
    [ "$(q '.services.llama-server.environment.TRANSFORMERS_OFFLINE')" = "1" ]
}
