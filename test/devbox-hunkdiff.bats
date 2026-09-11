#!/usr/bin/env bats

# herdr-hunk-diff launches hunk through the hunkdiff npm package's launcher
# (node_modules/hunkdiff/bin/hunk.cjs) when its `hunk.bin` is "auto". The image
# drops that package (it pulls in Bun, ~500 MB) but keeps the launcher itself,
# and points it at the hunk under /usr/local/bin with HUNK_BIN_PATH. The build
# then launches hunk the way the plugin resolves it, so a plugin release that
# changes the resolution fails the build instead of the review pane.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    DOCKERFILE="${REPO}/devbox/Dockerfile"
}

@test "the launcher is upstream's, not a copy kept here" {
    [ ! -e "${REPO}/devbox/herdr/hunk.cjs" ]
    ! grep -q 'herdr/hunk.cjs' "${DOCKERFILE}"
}

@test "the launcher is kept when the hunkdiff package is dropped" {
    grep -q 'node_modules/hunkdiff/bin/hunk.cjs' "${DOCKERFILE}"
}

@test "the launcher is pointed at the hunk the image installs" {
    grep -q '^ENV HUNK_BIN_PATH=/usr/local/bin/hunk$' "${DOCKERFILE}"
}

@test "the build launches hunk the way the plugin resolves it" {
    grep -q 'resolveHunkLauncher' "${DOCKERFILE}"
}
