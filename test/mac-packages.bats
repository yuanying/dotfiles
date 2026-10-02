#!/usr/bin/env bats

# bin/mac/setup-packages.sh and bin/mac/cleanup-packages.sh drive Homebrew on a
# Mac. A fake brew on PATH stands in for it: it keeps the installed formulae,
# casks and taps in files and logs every call, so the scripts' decisions can be
# checked on any host.
#
# The sshfs move is what these tests are about. sshfs used to come from the
# gromgit/fuse tap (deprecated upstream) or macFUSE's own SSHFS pkg; it now
# comes from FUSE-T. Two traps shape the cleanup side:
#
# - brew uninstall autoremoves every orphaned dependency, not just the ones
#   the removed formula pulled in. Removing sshfs-mac once took python@3.14
#   with it, so cleanup turns autoremove off.
# - The sshfs-mac cask uninstalls by pkg receipt, which deletes
#   /usr/local/bin/sshfs -- the same path fuse-t-sshfs installs to. Removing
#   the old cask after FUSE-T is in breaks FUSE-T's sshfs unless it is
#   reinstalled.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    BREW_STATE="${BATS_TEST_TMPDIR}/brew"
    BREW_LOG="${BATS_TEST_TMPDIR}/brew.log"
    mkdir -p "${FAKE_BIN}" "${BREW_STATE}"
    touch "${BREW_STATE}/formulae" "${BREW_STATE}/casks" "${BREW_STATE}/taps" "${BREW_LOG}"
    export BREW_STATE BREW_LOG

    cat > "${FAKE_BIN}/brew" <<'EOF'
#!/bin/bash
echo "AUTOREMOVE_OFF=${HOMEBREW_NO_AUTOREMOVE:-} $*" >> "${BREW_LOG}"
has() { grep -qx "$2" "${BREW_STATE}/$1"; }
drop() { grep -vx "$2" "${BREW_STATE}/$1" > "${BREW_STATE}/$1.new"; mv "${BREW_STATE}/$1.new" "${BREW_STATE}/$1"; }
case "$1 $2" in
    "list --formula") has formulae "$3" ;;
    "list --cask") has casks "$3" ;;
    "uninstall --formula") has formulae "$3" && drop formulae "$3" ;;
    "uninstall --cask") has casks "$3" && drop casks "$3" ;;
    "untap "*) has taps "$2" && drop taps "$2" ;;
    "tap ") cat "${BREW_STATE}/taps" ;;
    *) exit 0 ;;
esac
EOF
    # cleanup asks launchd about a retired agent, and setup installs herdr
    # plugins when herdr is on PATH. Neither is under test here.
    printf '#!/bin/bash\nexit 1\n' > "${FAKE_BIN}/launchctl"
    printf '#!/bin/bash\nexit 0\n' > "${FAKE_BIN}/herdr"
    chmod +x "${FAKE_BIN}"/*

    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    export PATH="${FAKE_BIN}:/usr/bin:/bin"

    SETUP="${REPO}/bin/mac/setup-packages.sh"
    CLEANUP="${REPO}/bin/mac/cleanup-packages.sh"
}

installed() { # <formulae|casks|taps> <name>
    echo "$2" >> "${BREW_STATE}/$1"
}

calls() { # <pattern>
    grep -E "$1" "${BREW_LOG}"
}

# bats does not fail a test on a bare `! cmd` (errexit ignores negated
# commands), so negative checks go through functions whose status counts.
no_calls() { # <pattern>
    ! grep -qE "$1" "${BREW_LOG}"
}

lacks() { # <formulae|casks|taps> <name>
    ! grep -qx "$2" "${BREW_STATE}/$1"
}

# --- setup ---

@test "setup installs FUSE-T and its sshfs" {
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    calls ' install --cask fuse-t$'
    calls ' install --cask macos-fuse-t/cask/fuse-t-sshfs$'
}

@test "setup trusts the FUSE-T tap before installing from it" {
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    tap=$(grep -nE ' tap macos-fuse-t/homebrew-cask$' "${BREW_LOG}" | cut -d: -f1)
    trust=$(grep -nE ' trust macos-fuse-t/cask$' "${BREW_LOG}" | cut -d: -f1)
    sshfs=$(grep -nE ' install --cask macos-fuse-t/cask/fuse-t-sshfs$' "${BREW_LOG}" | cut -d: -f1)
    [ -n "${tap}" ]
    [ -n "${trust}" ]
    [ -n "${sshfs}" ]
    [ "${tap}" -lt "${trust}" ]
    [ "${trust}" -lt "${sshfs}" ]
}

@test "setup no longer installs sshfs or macFUSE from anywhere else" {
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    no_calls 'sshfs-mac'
    no_calls 'macfuse'
    no_calls 'gromgit'
}

# --- cleanup ---

@test "cleanup removes the gromgit sshfs-mac formula with autoremove off" {
    installed formulae sshfs-mac
    run bash "${CLEANUP}"
    [ "$status" -eq 0 ]
    calls '^AUTOREMOVE_OFF=1 uninstall --formula sshfs-mac$'
    lacks formulae sshfs-mac
    [[ "$output" == *"sshfs-mac"* ]]
}

@test "cleanup drops the gromgit/fuse tap" {
    installed taps gromgit/fuse
    run bash "${CLEANUP}"
    [ "$status" -eq 0 ]
    calls ' untap gromgit/fuse$'
    lacks taps gromgit/fuse
    [[ "$output" == *"gromgit/fuse"* ]]
}

@test "cleanup removes macFUSE's sshfs-mac cask with autoremove off" {
    installed casks sshfs-mac
    run bash "${CLEANUP}"
    [ "$status" -eq 0 ]
    calls '^AUTOREMOVE_OFF=1 uninstall --cask sshfs-mac$'
    lacks casks sshfs-mac
}

@test "removing the old cask reinstalls FUSE-T's sshfs it would have deleted" {
    installed casks sshfs-mac
    installed casks fuse-t-sshfs
    run bash "${CLEANUP}"
    [ "$status" -eq 0 ]
    uninstall=$(grep -nE ' uninstall --cask sshfs-mac$' "${BREW_LOG}" | cut -d: -f1)
    reinstall=$(grep -nE ' reinstall --cask macos-fuse-t/cask/fuse-t-sshfs$' "${BREW_LOG}" | cut -d: -f1)
    [ -n "${uninstall}" ]
    [ -n "${reinstall}" ]
    [ "${uninstall}" -lt "${reinstall}" ]
}

@test "FUSE-T's sshfs is left alone when the old cask was not there" {
    installed casks fuse-t-sshfs
    run bash "${CLEANUP}"
    [ "$status" -eq 0 ]
    no_calls 'reinstall'
}

@test "cleanup leaves macFUSE itself installed" {
    installed casks macfuse
    installed casks sshfs-mac
    run bash "${CLEANUP}"
    [ "$status" -eq 0 ]
    no_calls 'uninstall .*macfuse'
    grep -qx macfuse "${BREW_STATE}/casks"
}

@test "cleanup with nothing left to remove changes nothing" {
    run bash "${CLEANUP}"
    [ "$status" -eq 0 ]
    no_calls 'uninstall|untap|reinstall'
    [[ "$output" == *"消すものは無かった"* ]]
}
