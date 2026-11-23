#!/usr/bin/env bats

load helpers

@test "the review rules match the SHA-256 recorded in SKILL.md" {
    cd "${REPO}/skills/web-design-guidelines"
    expected=$(sed -n 's/^- SHA-256: `\([0-9a-f]*\)`$/\1/p' SKILL.md)
    actual=$(shasum -a 256 references/command.md)
    [ "${actual%% *}" = "${expected}" ]
}
