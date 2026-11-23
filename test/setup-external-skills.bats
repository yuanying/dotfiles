#!/usr/bin/env bats

load helpers

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    export XDG_DATA_HOME="${HOME}/data"
    export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
    export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
    export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
    export UPSTREAM="${BATS_TEST_TMPDIR}/upstream"
    repo=github.com/example/skills
    clone="${XDG_DATA_HOME}/dotfiles/skill-repos/${repo}"
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
[ "$1 $2" = 'get -u' ] || exit 2
exec git clone -q "$UPSTREAM" "$GHQ_ROOT/$3"
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
    GHQ_ROOT="${XDG_DATA_HOME}/dotfiles/skill-repos" ghq get -u "${repo}"
    mv "${UPSTREAM}" "${UPSTREAM}.offline"

    run bash "${setup_skills}"
    [ "$status" -eq 0 ]
    [[ "$output" == *warning:* ]]
    [ "$(cat "${agents}/listed/SKILL.md")" = first ]
}

@test "a divergent clone is not merged or rebased" {
    GHQ_ROOT="${XDG_DATA_HOME}/dotfiles/skill-repos" ghq get -u "${repo}"
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
    GHQ_ROOT="${XDG_DATA_HOME}/dotfiles/skill-repos" ghq get -u "${repo}"
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
    GHQ_ROOT="${XDG_DATA_HOME}/dotfiles/skill-repos" ghq get -u "${repo}"
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

@test "a missing external clone that cannot be obtained does not block local skills" {
    mv "${UPSTREAM}" "${UPSTREAM}.offline"
    run bash "${setup_skills}"
    [ "$status" -eq 0 ]
    [[ "$output" == *warning:* ]]
    [ ! -e "${agents}/listed" ]
    [ -L "${agents}/local" ]
}
