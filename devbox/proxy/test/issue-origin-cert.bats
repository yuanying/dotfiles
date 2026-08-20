#!/usr/bin/env bats

# What is testable here is the half that does not involve Cloudflare: the key
# and CSR, the file modes, and refusing to destroy a key that cannot be
# recovered. Whether the real API likes the request body is field work.

load helpers

setup() {
    require openssl
    require jq
    require curl

    STATE="${BATS_TEST_TMPDIR}/state"
    PORT=$(python3 "${BATS_TEST_DIRNAME}/helpers/jwtfixture.py" freeport)
    REQUEST="${BATS_TEST_TMPDIR}/request.json"

    python3 "${BATS_TEST_DIRNAME}/helpers/fakecfapi.py" "${PORT}" "${REQUEST}" \
        > "${BATS_TEST_TMPDIR}/api.log" 2>&1 &
    API_PID=$!

    export CLOUDFLARE_API_BASE="http://127.0.0.1:${PORT}"
    export CLOUDFLARE_API_TOKEN=not-a-real-token

    local waited=0
    until curl -s -o /dev/null "http://127.0.0.1:${PORT}/"; do
        sleep 0.1
        waited=$((waited + 1))
        [ "${waited}" -lt 100 ] || return 1
    done
}

teardown() {
    [ -n "${API_PID:-}" ] && kill "${API_PID}" 2> /dev/null
    return 0
}

issue() {
    "${PROXY_BIN}/issue-origin-cert.sh" --zone example.org --state-dir "${STATE}" "$@"
}

@test "issuing writes a certificate and a key that belong together" {
    run issue
    [ "$status" -eq 0 ]

    # The strongest available check that the right pair landed on disk.
    local from_cert from_key
    from_cert=$(openssl x509 -in "${STATE}/certs/origin.pem" -noout -pubkey)
    from_key=$(openssl rsa -in "${STATE}/certs/origin.key" -pubout 2> /dev/null)
    [ "${from_cert}" = "${from_key}" ]
}

@test "the private key is not readable by anyone else" {
    issue
    [ "$(stat -c '%a' "${STATE}/certs/origin.key")" = "600" ]
}

@test "the request covers the wildcard and the apex" {
    issue
    [ "$(jq -r '.hostnames | join(",")' "${REQUEST}")" = "*.example.org,example.org" ]
    [ "$(jq -r '.request_type' "${REQUEST}")" = "origin-rsa" ]
    [ "$(jq -r '.csr' "${REQUEST}")" != "null" ]
}

@test "an existing key is not replaced without being asked" {
    issue
    local before
    before=$(cat "${STATE}/certs/origin.key")
    run issue
    [ "$status" -ne 0 ]
    [[ "$output" == *"--force"* ]]
    [ "$(cat "${STATE}/certs/origin.key")" = "${before}" ]
}

@test "--force replaces it" {
    issue
    local before
    before=$(cat "${STATE}/certs/origin.key")
    run issue --force
    [ "$status" -eq 0 ]
    [ "$(cat "${STATE}/certs/origin.key")" != "${before}" ]
}

@test "an API failure leaves nothing behind" {
    kill "${API_PID}"
    API_PID=
    run issue
    [ "$status" -ne 0 ]
    [ ! -e "${STATE}/certs/origin.key" ]
    [ ! -e "${STATE}/certs/origin.pem" ]
}
