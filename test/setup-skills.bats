#!/usr/bin/env bats

# bin/setup-skills.sh links skills/ into the two directories agents read from.
# It follows the same rules as yuanying/skills' install-skills.sh: both targets,
# every conflict found before anything is linked, and re-running is a no-op.
#
# The property that matters is the second one. A half-installed skill tree is
# worse than none, so a conflict anywhere means nothing is touched anywhere.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    SETUP="${REPO}/bin/setup-skills.sh"
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    AGENTS="${HOME}/.agents/skills"
    CLAUDE="${HOME}/.claude/skills"

    # Every skill the repository ships, which is what an argument-less run links.
    SKILLS=()
    for path in "${REPO}"/skills/*/; do
        [ -f "${path}/SKILL.md" ] || continue
        SKILLS+=("$(basename "${path}")")
    done

    # A checkout with more than one skill in it, and one directory that is not
    # a skill. The script finds its repository from where it sits, so a copy in
    # a temporary tree is the real script working on a different tree -- which
    # is how "one conflict stops every skill" can be tested at all while the
    # repository ships a single skill.
    FAKE="${BATS_TEST_TMPDIR}/checkout"
    mkdir -p "${FAKE}/bin" "${FAKE}/skills/alpha" "${FAKE}/skills/beta" "${FAKE}/skills/notaskill"
    cp "${SETUP}" "${FAKE}/bin/setup-skills.sh"
    echo 'alpha' > "${FAKE}/skills/alpha/SKILL.md"
    echo 'beta' > "${FAKE}/skills/beta/SKILL.md"
    echo 'notes' > "${FAKE}/skills/notaskill/README.md"
    FAKE_SETUP="${FAKE}/bin/setup-skills.sh"
}

@test "the repository ships at least one skill to link" {
    [ "${#SKILLS[@]}" -gt 0 ]
}

@test "every skill is linked into both target directories" {
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    for name in "${SKILLS[@]}"; do
        [ -L "${AGENTS}/${name}" ]
        [ -L "${CLAUDE}/${name}" ]
        [ "$(readlink "${AGENTS}/${name}")" = "${REPO}/skills/${name}" ]
        [ "$(readlink "${CLAUDE}/${name}")" = "${REPO}/skills/${name}" ]
    done
}

@test "the target directories are created when they do not exist" {
    [ ! -d "${AGENTS}" ]
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ -d "${AGENTS}" ]
    [ -d "${CLAUDE}" ]
}

@test "the link resolves to a SKILL.md" {
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ -f "${CLAUDE}/devbox-publish/SKILL.md" ]
}

@test "running it twice changes nothing and still succeeds" {
    bash "${SETUP}"
    before=$(find "${AGENTS}" "${CLAUDE}" -maxdepth 1 -mindepth 1 -printf '%p %l\n' | sort)

    run bash "${SETUP}"
    [ "$status" -eq 0 ]

    after=$(find "${AGENTS}" "${CLAUDE}" -maxdepth 1 -mindepth 1 -printf '%p %l\n' | sort)
    [ "${before}" = "${after}" ]
}

@test "a link that is already correct is reported, not relinked" {
    bash "${SETUP}"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [[ "$output" == *exists* ]]
}

@test "a real directory in the way is a conflict" {
    mkdir -p "${CLAUDE}/devbox-publish"
    run bash "${SETUP}"
    [ "$status" -ne 0 ]
    [[ "$output" == *conflict* ]]
}

@test "a conflict leaves what was in the way untouched" {
    mkdir -p "${CLAUDE}/devbox-publish"
    echo 'someone elses skill' > "${CLAUDE}/devbox-publish/SKILL.md"
    run bash "${SETUP}"
    [ "$status" -ne 0 ]
    [ ! -L "${CLAUDE}/devbox-publish" ]
    [ "$(cat "${CLAUDE}/devbox-publish/SKILL.md")" = 'someone elses skill' ]
}

@test "a conflict in one target stops the other target being linked at all" {
    # ~/.agents/skills is checked and linked first. A clash found later in
    # ~/.claude/skills has to prevent it, or the two go out of step.
    mkdir -p "${CLAUDE}/devbox-publish"
    run bash "${SETUP}"
    [ "$status" -ne 0 ]
    [ ! -e "${AGENTS}/devbox-publish" ]
}

@test "a conflict stops the skills that do not clash from being linked" {
    mkdir -p "${CLAUDE}/alpha"
    run bash "${FAKE_SETUP}"
    [ "$status" -ne 0 ]
    [ ! -e "${AGENTS}/beta" ]
    [ ! -e "${CLAUDE}/beta" ]
}

@test "with no conflict every skill in the tree is linked" {
    run bash "${FAKE_SETUP}"
    [ "$status" -eq 0 ]
    [ -L "${AGENTS}/alpha" ]
    [ -L "${AGENTS}/beta" ]
    [ -L "${CLAUDE}/alpha" ]
    [ -L "${CLAUDE}/beta" ]
}

@test "a directory in skills without a SKILL.md is not a skill" {
    run bash "${FAKE_SETUP}"
    [ "$status" -eq 0 ]
    [ ! -e "${CLAUDE}/notaskill" ]
}

@test "a symlink pointing somewhere else is a conflict and is not replaced" {
    mkdir -p "${CLAUDE}" "${BATS_TEST_TMPDIR}/elsewhere"
    ln -s "${BATS_TEST_TMPDIR}/elsewhere" "${CLAUDE}/devbox-publish"
    run bash "${SETUP}"
    [ "$status" -ne 0 ]
    [ "$(readlink "${CLAUDE}/devbox-publish")" = "${BATS_TEST_TMPDIR}/elsewhere" ]
    [ ! -e "${AGENTS}/devbox-publish" ]
}

@test "a broken symlink in the way is a conflict, not something to overwrite" {
    mkdir -p "${CLAUDE}"
    ln -s "${BATS_TEST_TMPDIR}/gone" "${CLAUDE}/devbox-publish"
    run bash "${SETUP}"
    [ "$status" -ne 0 ]
    [ ! -e "${AGENTS}/devbox-publish" ]
}

@test "a named skill links only that one" {
    run bash "${FAKE_SETUP}" skills/alpha
    [ "$status" -eq 0 ]
    [ -L "${CLAUDE}/alpha" ]
    [ ! -e "${CLAUDE}/beta" ]
}

@test "a named skill that does not exist is an error" {
    run bash "${SETUP}" skills/no-such-skill
    [ "$status" -ne 0 ]
    [ ! -d "${CLAUDE}" ]
}

@test "a named directory with no SKILL.md is an error" {
    run bash "${SETUP}" bin
    [ "$status" -ne 0 ]
    [ ! -d "${CLAUDE}" ]
}
