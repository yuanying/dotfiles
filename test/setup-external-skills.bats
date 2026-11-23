#!/usr/bin/env bats

load helpers

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    export GHQ_ROOT="${HOME}/src"
    export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
    export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
    export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
    export UPSTREAM="${BATS_TEST_TMPDIR}/upstream"
    repo=github.com/example/skills
    clone="${GHQ_ROOT}/${repo}"
    checkout="${BATS_TEST_TMPDIR}/dotfiles"
    manifest="${checkout}/skills/external.txt"
    setup_skills="${checkout}/bin/setup-skills.sh"
    agents="${HOME}/.agents/skills"
    claude="${HOME}/.claude/skills"

    mkdir -p "${HOME}" "${BATS_TEST_TMPDIR}/bin" "${checkout}/bin" "${checkout}/skills/local"
    cp "${REPO}/bin/setup-skills.sh" "${setup_skills}"
    touch "${checkout}/skills/local/SKILL.md"
    printf '%s skills/listed\n' "${repo}" > "${manifest}"
    git init -q -b main "${UPSTREAM}"
    mkdir -p "${UPSTREAM}/skills/listed" "${UPSTREAM}/skills/unlisted"
    printf 'first\n' > "${UPSTREAM}/skills/listed/SKILL.md"
    touch "${UPSTREAM}/skills/unlisted/SKILL.md"
    git -C "${UPSTREAM}" add skills
    git -C "${UPSTREAM}" commit -qm first

    cat > "${BATS_TEST_TMPDIR}/bin/ghq" <<'EOF'
#!/bin/sh
case "$1 $2" in
    'root --all') printf '%s\n' "$GHQ_ROOT" | tr ':' '\n' ;;
    'get -u') exec git clone -q "$UPSTREAM" "${GHQ_ROOT%%:*}/$3" ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "${BATS_TEST_TMPDIR}/bin/ghq"
}

@test "only skills listed in the manifest are linked into both targets" {
    run bash "${setup_skills}"
    [ "$status" -eq 0 ]
    for target in "${agents}" "${claude}"; do
        [ "$(readlink "${target}/listed")" = "${clone}/skills/listed" ]
        [ ! -e "${target}/unlisted" ]
    done
}

@test "an external skill conflict prevents local and external links in either target" {
    mkdir -p "${claude}/listed"
    run bash "${setup_skills}"
    [ "$status" -ne 0 ]
    [[ "$output" == *conflict* ]]
    [ ! -e "${agents}/listed" ]
    [ ! -e "${agents}/local" ]
    [ ! -e "${claude}/local" ]
}

@test "a later setup fast-forwards an existing clone to the latest upstream content" {
    bash "${setup_skills}"
    printf 'second\n' > "${UPSTREAM}/skills/listed/SKILL.md"
    git -C "${UPSTREAM}" commit -qam second

    run bash "${setup_skills}"
    [ "$status" -eq 0 ]
    [ "$(cat "${agents}/listed/SKILL.md")" = second ]
}

@test "a failed pull still links the cached clone" {
    ghq get -u "${repo}"
    mv "${UPSTREAM}" "${UPSTREAM}.offline"

    run bash "${setup_skills}"
    [ "$status" -eq 0 ]
    [[ "$output" == *warning:* ]]
    [ "$(cat "${agents}/listed/SKILL.md")" = first ]
}

@test "a divergent clone is not merged or rebased" {
    ghq get -u "${repo}"
    printf 'local\n' > "${clone}/skills/listed/SKILL.md"
    git -C "${clone}" commit -qam local
    before=$(git -C "${clone}" rev-parse HEAD)
    printf 'second\n' > "${UPSTREAM}/skills/listed/SKILL.md"
    git -C "${UPSTREAM}" commit -qam second

    run bash "${setup_skills}"
    [ "$status" -eq 0 ]
    [[ "$output" == *warning:* ]]
    [ "$(git -C "${clone}" rev-parse HEAD)" = "${before}" ]
    [ "$(cat "${agents}/listed/SKILL.md")" = local ]
}

@test "an existing clone with local changes is left untouched" {
    ghq get -u "${repo}"
    touch "${clone}/untracked"
    printf 'second\n' > "${UPSTREAM}/skills/listed/SKILL.md"
    git -C "${UPSTREAM}" commit -qam second

    run bash "${setup_skills}"
    [ "$status" -eq 0 ]
    [[ "$output" == *warning:* ]]
    [ "$(cat "${agents}/listed/SKILL.md")" = first ]
    [ -f "${clone}/untracked" ]
}

@test "a ref on an existing clone uses a fetched tag instead of the latest content" {
    ghq get -u "${repo}"
    git -C "${UPSTREAM}" tag pinned
    printf 'second\n' > "${UPSTREAM}/skills/listed/SKILL.md"
    git -C "${UPSTREAM}" commit -qam second
    printf '%s skills/listed pinned\n' "${repo}" > "${manifest}"

    run bash "${setup_skills}"
    [ "$status" -eq 0 ]
    [ "$(cat "${agents}/listed/SKILL.md")" = first ]
    [ "$(git -C "${clone}" rev-parse refs/tags/pinned)" = "$(git -C "${clone}" rev-parse HEAD)" ]
    ! git -C "${clone}" symbolic-ref -q HEAD
}

@test "a pin does not change a clone on a different local branch" {
    git -C "${UPSTREAM}" tag pinned
    ghq get -u "${repo}"
    git -C "${clone}" switch -qc my-work
    printf '%s skills/listed pinned\n' "${repo}" > "${manifest}"

    run bash "${setup_skills}"
    [ "$status" -eq 0 ]
    [[ "$output" == *warning:* ]]
    [ "$(git -C "${clone}" branch --show-current)" = my-work ]
    [ "$(readlink "${agents}/listed")" = "${clone}/skills/listed" ]
}

@test "an existing clone in a secondary ghq root is reused" {
    ghq get -u "${repo}"
    export GHQ_ROOT="${HOME}/new-root:${GHQ_ROOT}"

    run bash "${setup_skills}"
    [ "$status" -eq 0 ]
    [ "$(readlink "${agents}/listed")" = "${clone}/skills/listed" ]
    [ ! -e "${HOME}/new-root/${repo}" ]
}

@test "removing a pin resumes tracking the default branch" {
    git -C "${UPSTREAM}" tag pinned
    printf '%s skills/listed pinned\n' "${repo}" > "${manifest}"
    bash "${setup_skills}"
    printf 'second\n' > "${UPSTREAM}/skills/listed/SKILL.md"
    git -C "${UPSTREAM}" commit -qam second
    printf '%s skills/listed\n' "${repo}" > "${manifest}"

    run bash "${setup_skills}"
    [ "$status" -eq 0 ]
    [ "$(cat "${agents}/listed/SKILL.md")" = second ]
}

@test "a failure to query ghq roots still links a clone from the configured root" {
    ghq get -u "${repo}"
    printf '#!/bin/sh\nexit 1\n' > "${BATS_TEST_TMPDIR}/bin/ghq"

    run bash "${setup_skills}"
    [ "$status" -eq 0 ]
    [[ "$output" == *warning:* ]]
    [ "$(readlink "${agents}/listed")" = "${clone}/skills/listed" ]
}

@test "a missing external clone that cannot be obtained does not block local skills" {
    mv "${UPSTREAM}" "${UPSTREAM}.offline"
    run bash "${setup_skills}"
    [ "$status" -eq 0 ]
    [[ "$output" == *warning:* ]]
    [ ! -e "${agents}/listed" ]
    [ -L "${agents}/local" ]
}
