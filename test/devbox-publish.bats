#!/usr/bin/env bats

# The publishing skill: it edits the declaration file for this host, then does
# as much of the rest as the environment allows. The one thing it must never do
# is take a working proxy down -- so a configuration that does not validate
# means the reload is skipped, not attempted.

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

    # Stand-ins for the two scripts under devbox/proxy/bin. They record how
    # they were called; touching the marker files makes them misbehave the way
    # the real ones do.
    cat > "${PROXY}/bin/devbox-proxy" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${BATS_TEST_TMPDIR}/devbox-proxy.calls"
if [[ $1 == generate && -f ${BATS_TEST_TMPDIR}/generate-fails ]]; then
    echo "generate-traefik-config.sh: llama has no aud tag" >&2
    exit 1
fi
exit 0
EOF

    cat > "${PROXY}/bin/sync-cloudflare.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${BATS_TEST_TMPDIR}/sync.calls"
# The real one writes back the audience tag Cloudflare generated.
if [[ -f ${BATS_TEST_TMPDIR}/sync-writes-aud ]]; then
    yq -i '(.services[] | select(.aud == "")).aud = "audfromcloudflare"' "${DEVBOX_PROXY_CONFIG}"
fi
exit 0
EOF

    chmod +x "${PROXY}/bin/devbox-proxy" "${PROXY}/bin/sync-cloudflare.sh"

    export DEVBOX_PROXY_CONFIG="${CONFIG}"
    export DEVBOX_PROXY_DIR="${PROXY}"
    unset CLOUDFLARE_API_TOKEN

    cat > "${CONFIG}" <<'EOF'
zone: example.org
team_domain: acme.cloudflareaccess.com
origin: 2001:db8::1

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
    # This is how the skill is actually reached: ~/.claude/skills/<name> is a
    # link into the dotfiles checkout, and the checkout is not necessarily
    # ~/dotfiles.
    link_dir="${BATS_TEST_TMPDIR}/home/.claude/skills"
    mkdir -p "${link_dir}"
    ln -s "${REPO}/skills/devbox-publish" "${link_dir}/devbox-publish"

    unset DEVBOX_PROXY_CONFIG DEVBOX_PROXY_DIR
    run "${link_dir}/devbox-publish/bin/devbox-publish" where
    [ "$status" -eq 0 ]
    [[ "$output" == *"${REPO}"* ]]
    [[ "$output" == *"devbox/proxy/services.$(hostname -s).yaml"* ]]
}

@test "the declaration file is the one named after this host" {
    unset DEVBOX_PROXY_CONFIG
    : > "${PROXY}/services.yaml"
    : > "${PROXY}/services.$(hostname -s).yaml"
    run "${PUBLISH}" where
    [ "$status" -eq 0 ]
    [[ "$output" == *"services.$(hostname -s).yaml"* ]]
}

@test "the unnamed declaration file is the fallback" {
    unset DEVBOX_PROXY_CONFIG
    : > "${PROXY}/services.yaml"
    run "${PUBLISH}" where
    [ "$status" -eq 0 ]
    [[ "$output" == *"${PROXY}/services.yaml"* ]]
}

@test "where reports the zone the declaration file names" {
    run "${PUBLISH}" where
    [ "$status" -eq 0 ]
    [[ "$output" == *"example.org"* ]]
}

# ---------------------------------------------------------------------------
# Publishing
# ---------------------------------------------------------------------------

@test "publish adds the service to the declaration file" {
    run "${PUBLISH}" publish --name llama --port 8081 \
        --email someone@example.com --no-listen-check
    [ "$status" -eq 0 ]
    [ "$(yq '.services | length' "${CONFIG}")" -eq 1 ]
    [ "$(yq '.services[0].name' "${CONFIG}")" = llama ]
    [ "$(yq '.services[0].port' "${CONFIG}")" -eq 8081 ]
    [ "$(yq '.services[0].auth' "${CONFIG}")" = required ]
    [ "$(yq '.services[0].viewers.emails[0]' "${CONFIG}")" = someone@example.com ]
}

@test "publish records an empty aud for sync-cloudflare.sh to fill in" {
    run "${PUBLISH}" publish --name llama --port 8081 \
        --email someone@example.com --no-listen-check
    [ "$status" -eq 0 ]
    [ "$(yq '.services[0].aud' "${CONFIG}")" = "" ]
    [ "$(yq '.services[0] | has("aud")' "${CONFIG}")" = true ]
}

@test "publish accepts github organisations as viewers" {
    run "${PUBLISH}" publish --name llama --port 8081 \
        --github-org acme --github-org other --no-listen-check
    [ "$status" -eq 0 ]
    [ "$(yq '.services[0].viewers.github_orgs | length' "${CONFIG}")" -eq 2 ]
}

@test "publish leaves the declaration file readable, comments and all" {
    run "${PUBLISH}" publish --name llama --port 8081 \
        --email someone@example.com --no-listen-check
    [ "$status" -eq 0 ]
    # Flow style would be valid YAML and horrible to hand-edit afterwards.
    grep -q '^  - name: llama$' "${CONFIG}"
}

@test "publish with auth none needs no viewers and writes no aud" {
    run "${PUBLISH}" publish --name docs --port 8082 --auth none --no-listen-check
    [ "$status" -eq 0 ]
    [ "$(yq '.services[0].auth' "${CONFIG}")" = none ]
    [ "$(yq '.services[0] | has("aud")' "${CONFIG}")" = false ]
}

@test "publishing a second service keeps the first" {
    "${PUBLISH}" publish --name llama --port 8081 --email a@example.com --no-listen-check
    run "${PUBLISH}" publish --name docs --port 8082 --auth none --no-listen-check
    [ "$status" -eq 0 ]
    [ "$(yq '.services | length' "${CONFIG}")" -eq 2 ]
}

@test "publishing a name that already exists updates it and keeps its aud" {
    "${PUBLISH}" publish --name llama --port 8081 --email a@example.com --no-listen-check
    yq -i '(.services[] | select(.name == "llama")).aud = "alreadyissued"' "${CONFIG}"

    run "${PUBLISH}" publish --name llama --port 9090 --email a@example.com --no-listen-check
    [ "$status" -eq 0 ]
    [ "$(yq '.services | length' "${CONFIG}")" -eq 1 ]
    [ "$(yq '.services[0].port' "${CONFIG}")" -eq 9090 ]
    # Re-issuing the Access application would be a needless round trip, and the
    # origin would refuse every request until the new tag was committed.
    [ "$(yq '.services[0].aud' "${CONFIG}")" = alreadyissued ]
}

@test "what publish writes is accepted by the real generator" {
    require openssl
    "${PUBLISH}" publish --name llama --port 8081 --auth none --no-listen-check
    run "${REPO}/devbox/proxy/bin/generate-traefik-config.sh" \
        --config "${CONFIG}" --state-dir /state \
        --write-to "${BATS_TEST_TMPDIR}/generated"
    [ "$status" -eq 0 ]
    grep -q 'llama.example.org' "${BATS_TEST_TMPDIR}/generated/dynamic/services.yml"
    grep -q 'http://127.0.0.1:8081' "${BATS_TEST_TMPDIR}/generated/dynamic/services.yml"
}

# ---------------------------------------------------------------------------
# Validation, before anything is written
# ---------------------------------------------------------------------------

@test "a service name with a dot is refused" {
    run "${PUBLISH}" publish --name llama.gpu --port 8081 \
        --email a@example.com --no-listen-check
    [ "$status" -ne 0 ]
    [ "$(yq '.services | length' "${CONFIG}")" -eq 0 ]
}

@test "a service name that is not a DNS label is refused" {
    run "${PUBLISH}" publish --name 'Llama Server' --port 8081 \
        --email a@example.com --no-listen-check
    [ "$status" -ne 0 ]
    [ "$(yq '.services | length' "${CONFIG}")" -eq 0 ]
}

@test "a port outside the valid range is refused" {
    run "${PUBLISH}" publish --name llama --port 70000 \
        --email a@example.com --no-listen-check
    [ "$status" -ne 0 ]
    [ "$(yq '.services | length' "${CONFIG}")" -eq 0 ]
}

@test "a port that is not a number is refused" {
    run "${PUBLISH}" publish --name llama --port eight \
        --email a@example.com --no-listen-check
    [ "$status" -ne 0 ]
    [ "$(yq '.services | length' "${CONFIG}")" -eq 0 ]
}

@test "an unknown auth value is refused" {
    run "${PUBLISH}" publish --name llama --port 8081 --auth maybe \
        --email a@example.com --no-listen-check
    [ "$status" -ne 0 ]
    [ "$(yq '.services | length' "${CONFIG}")" -eq 0 ]
}

@test "an authenticated service with no viewers is refused" {
    # An Access application with no allow rule locks out everyone, including
    # whoever ran this.
    run "${PUBLISH}" publish --name llama --port 8081 --no-listen-check
    [ "$status" -ne 0 ]
    [[ "$output" == *viewer* ]]
    [ "$(yq '.services | length' "${CONFIG}")" -eq 0 ]
}

@test "a declaration file that does not exist is refused" {
    export DEVBOX_PROXY_CONFIG="${BATS_TEST_TMPDIR}/nope.yaml"
    run "${PUBLISH}" publish --name llama --port 8081 \
        --email a@example.com --no-listen-check
    [ "$status" -ne 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/nope.yaml" ]
}

@test "nothing is published when nothing is listening on the port" {
    port=$(free_port)
    run "${PUBLISH}" publish --name llama --port "${port}" --email a@example.com
    [ "$status" -ne 0 ]
    [ "$(yq '.services | length' "${CONFIG}")" -eq 0 ]
}

@test "a port that is listening passes the check" {
    port=$(start_server)
    run "${PUBLISH}" publish --name llama --port "${port}" --email a@example.com
    [ "$status" -eq 0 ]
    [ "$(yq '.services[0].port' "${CONFIG}")" -eq "${port}" ]
}

# ---------------------------------------------------------------------------
# What happens after the file is written
# ---------------------------------------------------------------------------

@test "with a token the Cloudflare sync runs and then the proxy reloads" {
    export CLOUDFLARE_API_TOKEN=pretend
    touch "${BATS_TEST_TMPDIR}/sync-writes-aud"
    run "${PUBLISH}" publish --name llama --port 8081 \
        --email a@example.com --no-listen-check
    [ "$status" -eq 0 ]
    [ -f "${BATS_TEST_TMPDIR}/sync.calls" ]
    called devbox-proxy reload
    [ "$(yq '.services[0].aud' "${CONFIG}")" = audfromcloudflare ]
}

@test "with no token the file is still written and the sync is skipped" {
    run "${PUBLISH}" publish --name llama --port 8081 \
        --email a@example.com --no-listen-check
    [ "$status" -eq 0 ]
    [ "$(yq '.services | length' "${CONFIG}")" -eq 1 ]
    [ ! -f "${BATS_TEST_TMPDIR}/sync.calls" ]
}

@test "with no token the commands left to run are printed" {
    run "${PUBLISH}" publish --name llama --port 8081 \
        --email a@example.com --no-listen-check
    [ "$status" -eq 0 ]
    [[ "$output" == *CLOUDFLARE_API_TOKEN* ]]
    [[ "$output" == *sync-cloudflare.sh* ]]
    [[ "$output" == *"devbox-proxy"*reload* ]]
}

@test "with no token a public service still reloads, because it can" {
    run "${PUBLISH}" publish --name docs --port 8082 --auth none --no-listen-check
    [ "$status" -eq 0 ]
    called devbox-proxy reload
}

@test "the proxy is not reloaded when the configuration does not validate" {
    # An authenticated service has no aud tag until the sync runs. Reloading
    # would stop Traefik and then fail to start it again, taking down every
    # service that was working.
    touch "${BATS_TEST_TMPDIR}/generate-fails"
    run "${PUBLISH}" publish --name llama --port 8081 \
        --email a@example.com --no-listen-check
    [ "$status" -eq 0 ]
    [ "$(yq '.services | length' "${CONFIG}")" -eq 1 ]
    called devbox-proxy generate
    run ! called devbox-proxy reload
}

@test "publishing asks for the declaration file to be committed" {
    run "${PUBLISH}" publish --name llama --port 8081 \
        --email a@example.com --no-listen-check
    [ "$status" -eq 0 ]
    [[ "$output" == *commit* ]]
}

@test "the Cloudflare token is never written into the declaration file" {
    export CLOUDFLARE_API_TOKEN=supersecrettoken
    touch "${BATS_TEST_TMPDIR}/sync-writes-aud"
    run "${PUBLISH}" publish --name llama --port 8081 \
        --email a@example.com --no-listen-check
    [ "$status" -eq 0 ]
    run ! grep -q supersecrettoken "${CONFIG}"
}

# ---------------------------------------------------------------------------
# Unpublishing
# ---------------------------------------------------------------------------

@test "unpublish removes the service from the declaration file" {
    "${PUBLISH}" publish --name llama --port 8081 --email a@example.com --no-listen-check
    run "${PUBLISH}" unpublish --name llama
    [ "$status" -eq 0 ]
    [ "$(yq '.services | length' "${CONFIG}")" -eq 0 ]
}

@test "unpublish leaves the other services alone" {
    "${PUBLISH}" publish --name llama --port 8081 --email a@example.com --no-listen-check
    "${PUBLISH}" publish --name docs --port 8082 --auth none --no-listen-check
    run "${PUBLISH}" unpublish --name llama
    [ "$status" -eq 0 ]
    [ "$(yq '.services | length' "${CONFIG}")" -eq 1 ]
    [ "$(yq '.services[0].name' "${CONFIG}")" = docs ]
}

@test "unpublish with a token prunes Cloudflare and reloads" {
    "${PUBLISH}" publish --name llama --port 8081 --email a@example.com --no-listen-check
    export CLOUDFLARE_API_TOKEN=pretend
    run "${PUBLISH}" unpublish --name llama
    [ "$status" -eq 0 ]
    called sync --prune
    called devbox-proxy reload
}

@test "unpublish without a token prints the prune command it did not run" {
    "${PUBLISH}" publish --name llama --port 8081 --email a@example.com --no-listen-check
    run "${PUBLISH}" unpublish --name llama
    [ "$status" -eq 0 ]
    [ ! -f "${BATS_TEST_TMPDIR}/sync.calls" ]
    [[ "$output" == *--prune* ]]
}

@test "unpublishing a name that is not declared is an error" {
    run "${PUBLISH}" unpublish --name absent
    [ "$status" -ne 0 ]
}

@test "unpublishing a name that is not declared changes nothing" {
    "${PUBLISH}" publish --name llama --port 8081 --email a@example.com --no-listen-check
    cp "${CONFIG}" "${BATS_TEST_TMPDIR}/before.yaml"
    run "${PUBLISH}" unpublish --name absent
    [ "$status" -ne 0 ]
    diff -u "${BATS_TEST_TMPDIR}/before.yaml" "${CONFIG}"
}

# ---------------------------------------------------------------------------
# Listing
# ---------------------------------------------------------------------------

@test "list reports what is published, with hostnames" {
    "${PUBLISH}" publish --name llama --port 8081 --email a@example.com --no-listen-check
    run "${PUBLISH}" list
    [ "$status" -eq 0 ]
    [[ "$output" == *llama.example.org* ]]
    [[ "$output" == *8081* ]]
}

@test "list on an empty declaration file says so and succeeds" {
    run "${PUBLISH}" list
    [ "$status" -eq 0 ]
}

@test "an unknown subcommand is an error and prints the usage" {
    run "${PUBLISH}" frobnicate
    [ "$status" -ne 0 ]
    [[ "$output" == *usage* ]]
}
