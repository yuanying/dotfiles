#!/usr/bin/env bats

load helpers

setup() {
    require yq
    require jq
}

golden() {
    local name=$1
    generate "${FIXTURES}/${name}/services.yaml" "${BATS_TEST_TMPDIR}/out"
    assert_same_file "${FIXTURES}/${name}/expected/traefik.yml" \
        "${BATS_TEST_TMPDIR}/out/traefik.yml"
    assert_same_file "${FIXTURES}/${name}/expected/dynamic/services.yml" \
        "${BATS_TEST_TMPDIR}/out/dynamic/services.yml"
}

@test "a single authenticated service generates a router, a service and a forwardAuth middleware" {
    golden basic
}

@test "auth defaults, an explicit forward auth port and declaration order are all honoured" {
    golden mixed
}

@test "a declaration with no services still produces a loadable config" {
    golden empty
}

@test "generating twice produces identical bytes" {
    generate "${FIXTURES}/mixed/services.yaml" "${BATS_TEST_TMPDIR}/first"
    generate "${FIXTURES}/mixed/services.yaml" "${BATS_TEST_TMPDIR}/second"
    assert_same_file "${BATS_TEST_TMPDIR}/first/traefik.yml" \
        "${BATS_TEST_TMPDIR}/second/traefik.yml"
    assert_same_file "${BATS_TEST_TMPDIR}/first/dynamic/services.yml" \
        "${BATS_TEST_TMPDIR}/second/dynamic/services.yml"
}

@test "the generated dynamic config is valid YAML" {
    generate "${FIXTURES}/mixed/services.yaml" "${BATS_TEST_TMPDIR}/out"
    run yq -e '.http.routers.llama.middlewares[0]' "${BATS_TEST_TMPDIR}/out/dynamic/services.yml"
    [ "$status" -eq 0 ]
    [ "$output" = "cf-access-llama" ]
}

@test "a public service gets no middleware at all" {
    generate "${FIXTURES}/mixed/services.yaml" "${BATS_TEST_TMPDIR}/out"
    # Not `yq -e`: a falsy result makes it add an error line to the output.
    run yq '.http.routers.sd | has("middlewares")' "${BATS_TEST_TMPDIR}/out/dynamic/services.yml"
    [ "$output" = "false" ]
}

@test "the default output directory is derived from the state directory" {
    "${PROXY_BIN}/generate-traefik-config.sh" \
        --config "${FIXTURES}/basic/services.yaml" \
        --state-dir "${BATS_TEST_TMPDIR}/state"
    [ -f "${BATS_TEST_TMPDIR}/state/traefik/traefik.yml" ]
    [ -f "${BATS_TEST_TMPDIR}/state/traefik/dynamic/services.yml" ]
}

# The image runs on more than one host -- anietta publishes different services
# from boucherie, and from a different IPv6 -- so the declaration file is
# per host, the way zshrc.<hostname> already is.

@test "the declaration file defaults to the one named after this host" {
    local dir="${BATS_TEST_TMPDIR}/proxy"
    mkdir -p "${dir}/bin"
    cp "${PROXY_BIN}/generate-traefik-config.sh" "${dir}/bin/"
    cp "${FIXTURES}/basic/services.yaml" "${dir}/services.$(hostname -s).yaml"
    cat > "${dir}/services.yaml" <<'EOF'
zone: wrong.example
services: []
EOF
    "${dir}/bin/generate-traefik-config.sh" --state-dir "${BATS_TEST_TMPDIR}/state"
    grep -q 'llama.example.org' "${BATS_TEST_TMPDIR}/state/traefik/dynamic/services.yml"
}

@test "an unnamed declaration file is the fallback" {
    local dir="${BATS_TEST_TMPDIR}/proxy"
    mkdir -p "${dir}/bin"
    cp "${PROXY_BIN}/generate-traefik-config.sh" "${dir}/bin/"
    cp "${FIXTURES}/basic/services.yaml" "${dir}/services.yaml"
    "${dir}/bin/generate-traefik-config.sh" --state-dir "${BATS_TEST_TMPDIR}/state"
    grep -q 'llama.example.org' "${BATS_TEST_TMPDIR}/state/traefik/dynamic/services.yml"
}
