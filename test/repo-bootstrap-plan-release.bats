#!/usr/bin/env bats

# skills/repo-bootstrap's plan-release.sh decides the weekly release of the
# repositories it is copied into. It releases the next patch version only when
# every commit since the latest vX.Y.Z tag is Renovate's and changes something
# that is released; anything else is left to a tag pushed by hand.
#
# The failure that matters is a release nobody asked for, so most cases here
# are the ones that must not release.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    PLAN="${REPO}/skills/repo-bootstrap/templates/common/.github/scripts/plan-release.sh"
    WORK="${BATS_TEST_TMPDIR}/repo"
    export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
    : > "${GITHUB_OUTPUT}"

    git init -q -b main "${WORK}"
    git -C "${WORK}" config user.name "yuanying"
    git -C "${WORK}" config user.email "yuanying@example.com"
    commit_as yuanying main.go "Add main"
}

# commit_as <author> <path> <subject>: change <path> and commit it as <author>.
commit_as() {
    mkdir -p "$(dirname "${WORK}/$2")"
    echo "$RANDOM" >> "${WORK}/$2"
    git -C "${WORK}" add "$2"
    git -C "${WORK}" -c user.name="$1" -c user.email="$1@example.com" commit -q -m "$3"
}

output_value() {
    sed -n "s/^$1=//p" "${GITHUB_OUTPUT}"
}

@test "no tag: nothing is released" {
    run "${PLAN}" "${WORK}"
    [ "$status" -eq 0 ]
    [[ "$output" == "no release: no vX.Y.Z tag"* ]]
    [ "$(output_value version)" = "" ]
}

@test "no commits since the tag: nothing is released" {
    git -C "${WORK}" tag v1.2.3
    run "${PLAN}" "${WORK}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no commits since v1.2.3"* ]]
    [ "$(output_value version)" = "" ]
}

@test "a person's commit since the tag: left to a release by hand" {
    git -C "${WORK}" tag v1.2.3
    commit_as "renovate[bot]" go.mod "chore(deps): update a"
    commit_as yuanying main.go "Fix a bug"
    run "${PLAN}" "${WORK}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"by yuanying are left to a release by hand"* ]]
    [ "$(output_value version)" = "" ]
}

@test "Renovate changed only workflows, renovate.json and docs: nothing is released" {
    git -C "${WORK}" tag v1.2.3
    commit_as "renovate[bot]" .github/workflows/ci.yml "chore(deps): update actions"
    commit_as "renovate[bot]" renovate.json "chore(deps): migrate config"
    commit_as "renovate[bot]" docs/usage.md "chore(deps): update docs"
    run "${PLAN}" "${WORK}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"change nothing that is released"* ]]
    [ "$(output_value version)" = "" ]
}

@test "RELEASE_IGNORE widens what is not released" {
    git -C "${WORK}" tag v1.2.3
    commit_as "renovate[bot]" hack/tool/go.mod "chore(deps): update a hack tool"
    RELEASE_IGNORE='^(\.github/|hack/)' run "${PLAN}" "${WORK}"
    [ "$status" -eq 0 ]
    [ "$(output_value version)" = "" ]
}

@test "only Renovate's commits changing the code: the next patch is released" {
    git -C "${WORK}" tag v1.2.9
    commit_as "renovate[bot]" go.mod "chore(deps): update a to v1.1.0"
    commit_as "renovate[bot]" go.sum "chore(deps): update b to v2.0.1"
    run "${PLAN}" "${WORK}"
    [ "$status" -eq 0 ]
    [[ "$output" == "release v1.2.10:"* ]]
    [ "$(output_value version)" = "v1.2.10" ]
    # The tag's annotation lists the commits, oldest first.
    grep -qxF -- "v1.2.10: dependency updates by Renovate" "${GITHUB_OUTPUT}"
    [ "$(grep -n -- '- chore(deps): update a to v1.1.0' "${GITHUB_OUTPUT}" | cut -d: -f1)" -lt \
      "$(grep -n -- '- chore(deps): update b to v2.0.1' "${GITHUB_OUTPUT}" | cut -d: -f1)" ]
}

@test "the latest tag is chosen by version, and other tags are ignored" {
    git -C "${WORK}" tag v1.9.0
    git -C "${WORK}" tag v1.10.0
    git -C "${WORK}" tag v2.0.0-rc.1
    git -C "${WORK}" tag latest
    commit_as "renovate[bot]" go.mod "chore(deps): update a"
    run "${PLAN}" "${WORK}"
    [ "$status" -eq 0 ]
    [ "$(output_value version)" = "v1.10.1" ]
}

@test "a tag not reachable from HEAD is not the starting point" {
    git -C "${WORK}" tag v1.0.0
    git -C "${WORK}" checkout -q -b other
    commit_as yuanying other.go "Work elsewhere"
    git -C "${WORK}" tag v9.0.0
    git -C "${WORK}" checkout -q main
    commit_as "renovate[bot]" go.mod "chore(deps): update a"
    run "${PLAN}" "${WORK}"
    [ "$status" -eq 0 ]
    [ "$(output_value version)" = "v1.0.1" ]
}

@test "merge commits by a person do not stop the release" {
    git -C "${WORK}" tag v1.0.0
    git -C "${WORK}" checkout -q -b renovate/a
    commit_as "renovate[bot]" go.mod "chore(deps): update a"
    git -C "${WORK}" checkout -q main
    git -C "${WORK}" merge -q --no-ff -m "Merge pull request #1" renovate/a
    run "${PLAN}" "${WORK}"
    [ "$status" -eq 0 ]
    [ "$(output_value version)" = "v1.0.1" ]
}

@test "without GITHUB_OUTPUT it only prints the decision" {
    unset GITHUB_OUTPUT
    git -C "${WORK}" tag v1.0.0
    commit_as "renovate[bot]" go.mod "chore(deps): update a"
    run "${PLAN}" "${WORK}"
    [ "$status" -eq 0 ]
    [[ "$output" == "release v1.0.1:"* ]]
}
