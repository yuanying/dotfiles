#!/usr/bin/env bats

# The devbox image carries the pi coding agent. Its version is pinned by an
# `ARG PI_VERSION` in devbox/Dockerfile, which Renovate follows and which
# bin/mac/setup-packages.sh reads, so the devbox and a Mac run the same pi.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    DOCKERFILE="${REPO}/devbox/Dockerfile"
}

@test "the pi version is pinned under a renovate annotation for its npm package" {
    grep -A1 -x '# renovate: datasource=npm depName=@earendil-works/pi-coding-agent' "${DOCKERFILE}" \
        | grep -Eq '^ARG PI_VERSION=[0-9]+\.[0-9]+\.[0-9]+$'
}

@test "pi is installed from npm at the pinned version without install scripts" {
    grep -q 'npm install -g --ignore-scripts @earendil-works/pi-coding-agent@${PI_VERSION}' "${DOCKERFILE}"
}

@test "pi is installed after the system node it runs on" {
    node=$(grep -n '^COPY --from=node_builder /usr/local/bin/node ' "${DOCKERFILE}" | cut -d: -f1)
    pi=$(grep -n 'pi-coding-agent@${PI_VERSION}' "${DOCKERFILE}" | cut -d: -f1)
    [ -n "${node}" ]
    [ -n "${pi}" ]
    [ "${node}" -lt "${pi}" ]
}
