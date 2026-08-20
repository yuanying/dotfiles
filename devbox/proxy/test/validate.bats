#!/usr/bin/env bats

# A bad declaration file has to fail loudly at generation time. The alternative
# is a proxy that starts, serves the wrong thing, and says nothing.

load helpers

setup() {
    require yq
    require jq
    CONFIG="${BATS_TEST_TMPDIR}/services.yaml"
}

# Writes stdin to CONFIG and generates from it.
try() {
    cat > "${CONFIG}"
    run generate "${CONFIG}" "${BATS_TEST_TMPDIR}/out"
}

@test "a service name with a dot is refused, because Universal SSL stops at one level" {
    try <<'EOF'
zone: example.org
team_domain: acme.cloudflareaccess.com
services:
  - name: llama.gpu
    port: 8081
    auth: none
EOF
    [ "$status" -ne 0 ]
    [[ "$output" == *"llama.gpu"* ]]
    [[ "$output" == *"one level"* ]]
}

@test "a service name that is not a DNS label is refused" {
    try <<'EOF'
zone: example.org
team_domain: acme.cloudflareaccess.com
services:
  - name: Llama_Server
    port: 8081
    auth: none
EOF
    [ "$status" -ne 0 ]
    [[ "$output" == *"Llama_Server"* ]]
}

@test "a duplicate service name is refused" {
    try <<'EOF'
zone: example.org
team_domain: acme.cloudflareaccess.com
services:
  - name: llama
    port: 8081
    auth: none
  - name: llama
    port: 8082
    auth: none
EOF
    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate"* ]]
}

@test "a missing port is refused" {
    try <<'EOF'
zone: example.org
team_domain: acme.cloudflareaccess.com
services:
  - name: llama
    auth: none
EOF
    [ "$status" -ne 0 ]
    [[ "$output" == *"port"* ]]
}

@test "a port outside the valid range is refused" {
    try <<'EOF'
zone: example.org
team_domain: acme.cloudflareaccess.com
services:
  - name: llama
    port: 70000
    auth: none
EOF
    [ "$status" -ne 0 ]
    [[ "$output" == *"port"* ]]
}

@test "an authenticated service without an aud tag is refused" {
    try <<'EOF'
zone: example.org
team_domain: acme.cloudflareaccess.com
services:
  - name: llama
    port: 8081
    auth: required
EOF
    [ "$status" -ne 0 ]
    [[ "$output" == *"aud"* ]]
    [[ "$output" == *"llama"* ]]
}

@test "an unknown auth value is refused" {
    try <<'EOF'
zone: example.org
team_domain: acme.cloudflareaccess.com
services:
  - name: llama
    port: 8081
    auth: maybe
EOF
    [ "$status" -ne 0 ]
    [[ "$output" == *"maybe"* ]]
}

@test "a missing zone is refused" {
    try <<'EOF'
team_domain: acme.cloudflareaccess.com
services:
  - name: llama
    port: 8081
    auth: none
EOF
    [ "$status" -ne 0 ]
    [[ "$output" == *"zone"* ]]
}

@test "a missing team domain is refused when a service needs authentication" {
    try <<'EOF'
zone: example.org
services:
  - name: llama
    port: 8081
    aud: aud-llama
EOF
    [ "$status" -ne 0 ]
    [[ "$output" == *"team_domain"* ]]
}

@test "a missing team domain is fine when nothing needs authentication" {
    try <<'EOF'
zone: example.org
services:
  - name: sd
    port: 7860
    auth: none
EOF
    [ "$status" -eq 0 ]
}

@test "a config file that does not exist is refused" {
    run generate "${BATS_TEST_TMPDIR}/nope.yaml" "${BATS_TEST_TMPDIR}/out"
    [ "$status" -ne 0 ]
}

@test "nothing is written when validation fails" {
    try <<'EOF'
zone: example.org
services:
  - name: llama
    port: 8081
EOF
    [ "$status" -ne 0 ]
    [ ! -e "${BATS_TEST_TMPDIR}/out/dynamic/services.yml" ]
}
