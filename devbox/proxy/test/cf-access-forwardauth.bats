#!/usr/bin/env bats

# The verifier is what stands between the backend and anyone who has learnt the
# devbox's IPv6 address, so the interesting cases here are the negative ones.

load helpers

FIXTURE=

setup() {
    require openssl
    require curl

    KEYS="${BATS_TEST_TMPDIR}/keys"
    python3 "${BATS_TEST_DIRNAME}/helpers/jwtfixture.py" keygen "${KEYS}"

    PORT=$(python3 "${BATS_TEST_DIRNAME}/helpers/jwtfixture.py" freeport)
    "${PROXY_BIN}/cf-access-forwardauth" \
        --team-domain acme.cloudflareaccess.com \
        --port "${PORT}" \
        --certs-url "file://${KEYS}/jwks.json" \
        > "${BATS_TEST_TMPDIR}/verifier.log" 2>&1 &
    VERIFIER_PID=$!

    local waited=0
    until curl -sf "http://127.0.0.1:${PORT}/healthz" > /dev/null 2>&1; do
        kill -0 "${VERIFIER_PID}" 2> /dev/null || {
            cat "${BATS_TEST_TMPDIR}/verifier.log" >&2
            return 1
        }
        sleep 0.1
        waited=$((waited + 1))
        [ "${waited}" -lt 100 ] || return 1
    done
}

teardown() {
    [ -n "${VERIFIER_PID:-}" ] && kill "${VERIFIER_PID}" 2> /dev/null
    return 0
}

mint() {
    local overrides=$1
    [ -n "${overrides}" ] || overrides='{}'
    python3 "${BATS_TEST_DIRNAME}/helpers/jwtfixture.py" token "${KEYS}" "${overrides}"
}

# Prints the status code, with the response headers left in headers.txt.
verify() {
    local jwt=$1 aud=${2:-aud-llama}
    local args=(-s -o /dev/null -D "${BATS_TEST_TMPDIR}/headers.txt" -w '%{http_code}')
    [ -n "${jwt}" ] && args+=(-H "Cf-Access-Jwt-Assertion: ${jwt}")
    curl "${args[@]}" "http://127.0.0.1:${PORT}/verify?service=llama&aud=${aud}"
}

@test "a valid token is accepted" {
    [ "$(verify "$(mint)")" = "200" ]
}

@test "the identity is handed to the backend" {
    verify "$(mint)" > /dev/null
    grep -qi '^X-Devbox-Access-Email: someone@example.com' "${BATS_TEST_TMPDIR}/headers.txt"
    grep -qi '^X-Devbox-Access-Sub: a1b2c3' "${BATS_TEST_TMPDIR}/headers.txt"
}

@test "a request with no assertion header is refused" {
    [ "$(verify "")" = "403" ]
}

@test "a token whose signature has been tampered with is refused" {
    jwt=$(mint)
    # Flip the last character of the signature, keeping the token well-formed.
    last=${jwt: -1}
    [ "${last}" = "A" ] && replacement=B || replacement=A
    [ "$(verify "${jwt%?}${replacement}")" = "403" ]
}

@test "a token signed by some other key is refused" {
    other="${BATS_TEST_TMPDIR}/other"
    python3 "${BATS_TEST_DIRNAME}/helpers/jwtfixture.py" keygen "${other}"
    [ "$(verify "$(python3 "${BATS_TEST_DIRNAME}/helpers/jwtfixture.py" token "${other}" '{}')")" = "403" ]
}

@test "a token minted for another application is refused" {
    [ "$(verify "$(mint)" aud-notebook)" = "403" ]
}

@test "a token from another team is refused" {
    [ "$(verify "$(mint '{"iss": "https://someone-else.cloudflareaccess.com"}')")" = "403" ]
}

@test "an expired token is refused" {
    [ "$(verify "$(mint '{"exp": 1000000000}')")" = "403" ]
}

@test "a token that is not valid yet is refused" {
    [ "$(verify "$(mint '{"nbf": 4000000000}')")" = "403" ]
}

@test "a token naming an unknown key is refused" {
    [ "$(verify "$(mint '{"header": {"kid": "nosuchkey"}}')")" = "403" ]
}

@test "alg=none is refused" {
    jwt=$(mint '{"header": {"alg": "none"}}')
    [ "$(verify "${jwt%.*}.")" = "403" ]
}

@test "a symmetric algorithm is refused" {
    [ "$(verify "$(mint '{"header": {"alg": "HS256"}}')")" = "403" ]
}

@test "garbage in the header is refused" {
    [ "$(verify "not-a-jwt")" = "403" ]
    [ "$(verify "a.b.c")" = "403" ]
}

@test "a request naming no application is refused" {
    jwt=$(mint)
    code=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Cf-Access-Jwt-Assertion: ${jwt}" \
        "http://127.0.0.1:${PORT}/verify?service=llama")
    [ "${code}" = "403" ]
}
