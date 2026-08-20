#!/usr/bin/env bats

# The publishing skill: it edits the declaration file for this host and reloads
# the proxy. docs/adr/0005 took the third step away -- there is no Cloudflare to
# reconcile and no token to have or not have -- so publishing now either works
# or fails, with nothing in between.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    require yq
    require jq
    require python3

    PUBLISH="${REPO}/skills/devbox-publish/bin/devbox-publish"
    CONFIG="${BATS_TEST_TMPDIR}/services.yaml"
    PROXY="${BATS_TEST_TMPDIR}/proxy"
    mkdir -p "${PROXY}/bin"

    # A stand-in for the wrapper, recording how it was called. Touching the
    # marker makes it fail the way a wrapper whose check did not pass would.
    cat > "${PROXY}/bin/devbox-proxy" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${BATS_TEST_TMPDIR}/devbox-proxy.calls"
if [[ -f ${BATS_TEST_TMPDIR}/reload-fails ]]; then
    echo "devbox-proxy: the declaration file does not validate" >&2
    exit 1
fi
exit 0
EOF
    chmod +x "${PROXY}/bin/devbox-proxy"

    export DEVBOX_PROXY_CONFIG="${CONFIG}"
    export DEVBOX_PROXY_DIR="${PROXY}"

    cat > "${CONFIG}" <<'EOF'
# Services this devbox publishes.
zone: example.org

defaults:
  auth: required

services: []
EOF
}

teardown() {
    if [ -f "${BATS_TEST_TMPDIR}/server.pid" ]; then
        kill "$(cat "${BATS_TEST_TMPDIR}/server.pid")" 2> /dev/null
    fi
    return 0
}

# A real listening socket, so that the port check is exercised rather than
# stubbed out.
start_server() {
    local port
    port=$(free_port)
    python3 -m http.server "${port}" --bind 127.0.0.1 > /dev/null 2>&1 &
    echo $! > "${BATS_TEST_TMPDIR}/server.pid"
    for _ in $(seq 50); do
        if (exec 3<> "/dev/tcp/127.0.0.1/${port}") 2> /dev/null; then
            echo "${port}"
            return 0
        fi
        sleep 0.1
    done
    return 1
}

service() {
    yq -o=json ".services[] | select(.name == \"$1\")" "${CONFIG}"
}

called() {
    grep -qF -- "$2" "${BATS_TEST_TMPDIR}/$1.calls"
}

# ---------------------------------------------------------------------------
# Finding the checkout
# ---------------------------------------------------------------------------

@test "where resolves the checkout through the symlink the skill is loaded by" {
    local link="${BATS_TEST_TMPDIR}/skills"
    mkdir -p "${link}"
    ln -s "${REPO}/skills/devbox-publish" "${link}/devbox-publish"

    run -0 "${link}/devbox-publish/bin/devbox-publish" where
    [[ "${output}" == *"${REPO}"* ]]
}

@test "the declaration file is the one named after this host" {
    unset DEVBOX_PROXY_CONFIG
    local named="${PROXY}/services.$(hostname -s).yaml"
    cp "${CONFIG}" "${named}"

    run -0 "${PUBLISH}" where
    [[ "${output}" == *"${named}"* ]]
}

@test "the unnamed declaration file is the fallback" {
    unset DEVBOX_PROXY_CONFIG
    cp "${CONFIG}" "${PROXY}/services.yaml"

    run -0 "${PUBLISH}" where
    [[ "${output}" == *"${PROXY}/services.yaml"* ]]
}

@test "where reports the zone the declaration file names" {
    run -0 "${PUBLISH}" where
    [[ "${output}" == *"example.org"* ]]
}

# ---------------------------------------------------------------------------
# Publishing
# ---------------------------------------------------------------------------

@test "publish adds the service to the declaration file" {
    run -0 "${PUBLISH}" publish --name llama --port 8081 \
        --github-login yuanying --no-listen-check

    [ "$(yq -r '.services[0].name' "${CONFIG}")" = llama ]
    [ "$(yq -r '.services[0].port' "${CONFIG}")" = 8081 ]
    [ "$(yq -r '.services[0].auth' "${CONFIG}")" = required ]
    [ "$(yq -r '.services[0].viewers.logins[0]' "${CONFIG}")" = yuanying ]
}

# docs/adr/0007 replaced email addresses with GitHub account names.
@test "publish writes no audience tag and no email addresses" {
    run -0 "${PUBLISH}" publish --name llama --port 8081 \
        --github-login yuanying --no-listen-check

    [ "$(service llama | yq -r '.aud // "absent"')" = absent ]
    [ "$(service llama | yq -r '.viewers.emails // "absent"')" = absent ]
}

@test "publish accepts github organisations as viewers" {
    run -0 "${PUBLISH}" publish --name llama --port 8081 \
        --github-org acme --no-listen-check

    [ "$(service llama | yq -r '.viewers.github_orgs[0]')" = acme ]
}

@test "publish accepts more than one of each" {
    run -0 "${PUBLISH}" publish --name llama --port 8081 \
        --github-login yuanying --github-login someone \
        --github-org acme --no-listen-check

    [ "$(service llama | yq -r '.viewers.logins | length')" = 2 ]
    [ "$(service llama | yq -r '.viewers.github_orgs | length')" = 1 ]
}

@test "publish leaves the declaration file readable, comments and all" {
    run -0 "${PUBLISH}" publish --name llama --port 8081 \
        --github-login yuanying --no-listen-check

    grep -q "^# Services this devbox publishes" "${CONFIG}"
}

@test "publish with auth none needs no viewers" {
    run -0 "${PUBLISH}" publish --name docs --port 8080 --auth none --no-listen-check

    [ "$(service docs | yq -r '.auth')" = none ]
    [ "$(service docs | yq -r '.viewers // "absent"')" = absent ]
}

@test "publishing a second service keeps the first" {
    run -0 "${PUBLISH}" publish --name llama --port 8081 --github-login yuanying --no-listen-check
    run -0 "${PUBLISH}" publish --name docs --port 8080 --auth none --no-listen-check

    [ "$(yq -r '.services | length' "${CONFIG}")" = 2 ]
    [ "$(service llama | yq -r '.port')" = 8081 ]
}

@test "publishing a name that already exists updates it" {
    run -0 "${PUBLISH}" publish --name llama --port 8081 --github-login yuanying --no-listen-check
    run -0 "${PUBLISH}" publish --name llama --port 9090 --github-login yuanying --no-listen-check

    [ "$(yq -r '.services | length' "${CONFIG}")" = 1 ]
    [ "$(service llama | yq -r '.port')" = 9090 ]
}

# The parser is the authority on what is valid, so what this writes has to
# survive it. Anything else and publishing produces a file the proxy refuses.
@test "what publish writes is accepted by the real parser" {
    require go
    run -0 "${PUBLISH}" publish --name llama --port 8081 \
        --github-login yuanying --github-org acme --no-listen-check
    run -0 "${PUBLISH}" publish --name docs --port 8080 --auth none --no-listen-check

    run -0 env -C "${REPO}/devbox/proxy/proxyd" go run . check --config "${CONFIG}"
    [[ "${output}" == *"llama.example.org"* ]]
    [[ "${output}" == *"docs.example.org"* ]]
}

# ---------------------------------------------------------------------------
# What it refuses
# ---------------------------------------------------------------------------

@test "a service name with a dot is refused" {
    run -1 "${PUBLISH}" publish --name llama.gpu --port 8081 --github-login yuanying --no-listen-check
    [[ "${output}" == *"one label"* ]]
    [ "$(yq -r '.services | length' "${CONFIG}")" = 0 ]
}

@test "a service name that is not a DNS label is refused" {
    run -1 "${PUBLISH}" publish --name "LLAMA" --port 8081 --github-login yuanying --no-listen-check
    [ "$(yq -r '.services | length' "${CONFIG}")" = 0 ]
}

# docs/adr/0007: auth.<zone> is where the login happens.
@test "the reserved name auth is refused" {
    run -1 "${PUBLISH}" publish --name auth --port 8081 --github-login yuanying --no-listen-check
    [[ "${output}" == *"reserved"* ]]
    [ "$(yq -r '.services | length' "${CONFIG}")" = 0 ]
}

@test "a port outside the valid range is refused" {
    run -1 "${PUBLISH}" publish --name llama --port 70000 --github-login yuanying --no-listen-check
    [ "$(yq -r '.services | length' "${CONFIG}")" = 0 ]
}

@test "a port that is not a number is refused" {
    run -1 "${PUBLISH}" publish --name llama --port eighty --github-login yuanying --no-listen-check
    [ "$(yq -r '.services | length' "${CONFIG}")" = 0 ]
}

@test "an unknown auth value is refused" {
    run -1 "${PUBLISH}" publish --name llama --port 8081 --auth maybe --no-listen-check
    [ "$(yq -r '.services | length' "${CONFIG}")" = 0 ]
}

@test "an authenticated service with no viewers is refused" {
    run -1 "${PUBLISH}" publish --name llama --port 8081 --no-listen-check
    [[ "${output}" == *"viewer"* ]]
    [ "$(yq -r '.services | length' "${CONFIG}")" = 0 ]
}

@test "a declaration file that does not exist is refused" {
    rm "${CONFIG}"
    run -1 "${PUBLISH}" publish --name llama --port 8081 --github-login yuanying --no-listen-check
}

@test "nothing is published when nothing is listening on the port" {
    local port
    port=$(free_port)
    run -1 "${PUBLISH}" publish --name llama --port "${port}" --github-login yuanying
    [ "$(yq -r '.services | length' "${CONFIG}")" = 0 ]
}

@test "a port that is listening passes the check" {
    local port
    port=$(start_server)
    run -0 "${PUBLISH}" publish --name llama --port "${port}" --github-login yuanying
    [ "$(service llama | yq -r '.name')" = llama ]
}

# ---------------------------------------------------------------------------
# Reloading
# ---------------------------------------------------------------------------

@test "publishing reloads the proxy" {
    run -0 "${PUBLISH}" publish --name llama --port 8081 --github-login yuanying --no-listen-check
    called devbox-proxy reload
}

# There is no half-done state left: 0005 removed the step that could not be
# completed without a token, so publishing either works or reports why not.
@test "a reload that fails is reported and the file keeps what was written" {
    touch "${BATS_TEST_TMPDIR}/reload-fails"
    run -1 "${PUBLISH}" publish --name llama --port 8081 --github-login yuanying --no-listen-check

    [ "$(service llama | yq -r '.name')" = llama ]
    [[ "${output}" == *"does not validate"* || "${output}" == *"reload"* ]]
}

@test "publishing asks for the declaration file to be committed" {
    run -0 "${PUBLISH}" publish --name llama --port 8081 --github-login yuanying --no-listen-check
    [[ "${output}" == *"commit"* ]]
}

@test "no Cloudflare token is ever consulted" {
    export CLOUDFLARE_API_TOKEN="should-not-matter"
    run -0 "${PUBLISH}" publish --name llama --port 8081 --github-login yuanying --no-listen-check

    ! grep -qF "should-not-matter" "${CONFIG}"
    [[ "${output}" != *"CLOUDFLARE"* ]]
}

# ---------------------------------------------------------------------------
# Unpublishing
# ---------------------------------------------------------------------------

@test "unpublish removes the service from the declaration file" {
    run -0 "${PUBLISH}" publish --name llama --port 8081 --github-login yuanying --no-listen-check
    run -0 "${PUBLISH}" unpublish --name llama

    [ "$(yq -r '.services | length' "${CONFIG}")" = 0 ]
}

@test "unpublish leaves the other services alone" {
    run -0 "${PUBLISH}" publish --name llama --port 8081 --github-login yuanying --no-listen-check
    run -0 "${PUBLISH}" publish --name docs --port 8080 --auth none --no-listen-check
    run -0 "${PUBLISH}" unpublish --name llama

    [ "$(yq -r '.services | length' "${CONFIG}")" = 1 ]
    [ "$(service docs | yq -r '.name')" = docs ]
}

@test "unpublish reloads the proxy" {
    run -0 "${PUBLISH}" publish --name llama --port 8081 --github-login yuanying --no-listen-check
    rm -f "${BATS_TEST_TMPDIR}/devbox-proxy.calls"
    run -0 "${PUBLISH}" unpublish --name llama
    called devbox-proxy reload
}

@test "unpublishing a name that is not declared is an error" {
    run -1 "${PUBLISH}" unpublish --name absent
}

@test "unpublishing a name that is not declared changes nothing" {
    run -0 "${PUBLISH}" publish --name llama --port 8081 --github-login yuanying --no-listen-check
    local before
    before=$(cat "${CONFIG}")

    run -1 "${PUBLISH}" unpublish --name absent
    [ "$(cat "${CONFIG}")" = "${before}" ]
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

@test "list reports what is published, with hostnames" {
    run -0 "${PUBLISH}" publish --name llama --port 8081 --github-login yuanying --no-listen-check
    run -0 "${PUBLISH}" list

    [[ "${output}" == *"llama.example.org"* ]]
    [[ "${output}" == *"8081"* ]]
}

@test "list on an empty declaration file says so and succeeds" {
    run -0 "${PUBLISH}" list
    [[ "${output}" == *"nothing"* ]]
}

@test "an unknown subcommand is an error and prints the usage" {
    run -2 "${PUBLISH}" frobnicate
    [[ "${output}" == *"usage"* ]]
}
