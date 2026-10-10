#!/usr/bin/env bats

# bin/setup-pi.sh hands the pi coding agent the settings this repository keeps
# under pi/, the same way on the devbox and on a Mac.
#
# pi writes its own settings.json (/settings, the changelog it last showed) and
# pi-web-access writes web-search.json (the curator switch), so neither can be a
# symlink. The repository's keys are merged over what is there instead, in the
# order local < common < this host, as Claude Code's settings.json is.
#
# The packages the repository declares are then installed with `pi install`,
# which is idempotent: an entry already in settings.json is not duplicated, and
# a new version replaces the old entry. A fake pi on PATH logs those calls.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    require jq

    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${HOME}"
    unset PI_CODING_AGENT_DIR
    AGENT="${HOME}/.pi/agent"

    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    PI_LOG="${BATS_TEST_TMPDIR}/pi.log"
    mkdir -p "${FAKE_BIN}"
    touch "${PI_LOG}"
    export PI_LOG
    cat > "${FAKE_BIN}/pi" <<'EOF'
#!/bin/bash
echo "$*" >> "${PI_LOG}"
[[ -n ${PI_FAIL:-} && $* == *"${PI_FAIL}"* ]] && exit 1
exit 0
EOF
    printf '#!/bin/bash\necho testhost\n' > "${FAKE_BIN}/hostname"
    chmod +x "${FAKE_BIN}"/*
    export PATH="${FAKE_BIN}:${PATH}"

    # The script finds pi/ from where it sits, so a copy in a temporary tree is
    # the real script working on settings the test controls.
    FAKE="${BATS_TEST_TMPDIR}/checkout"
    mkdir -p "${FAKE}/bin" "${FAKE}/pi"
    cp "${REPO}/bin/setup-pi.sh" "${FAKE}/bin/setup-pi.sh"
    cat > "${FAKE}/pi/settings.json" <<'EOF'
{
  "packages": [
    "npm:pi-alpha@1.0.0",
    { "source": "npm:@scope/pi-beta@2.0.0", "skills": [] }
  ],
  "theme": "dark"
}
EOF
    echo '{ "provider": "searxng", "fetch": { "timeout": 30 } }' > "${FAKE}/pi/web-search.json"
    echo '{ "tui.editor.historyPrevious": "ctrl+p", "tui.editor.historyNext": "ctrl+n", "tui.select.up": ["up", "ctrl+p"], "tui.select.down": ["down", "ctrl+n"] }' > "${FAKE}/pi/keybindings.json"
    SETUP="${FAKE}/bin/setup-pi.sh"
}

pi_calls() {
    cat "${PI_LOG}"
}

@test "keybindings are merged while preserving unrelated local bindings" {
    mkdir -p "${AGENT}"
    echo '{ "tui.select.up": "k", "app.editor.external": "ctrl+g" }' > "${AGENT}/keybindings.json"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    jq -e '."tui.editor.historyPrevious" == "ctrl+p" and ."tui.editor.historyNext" == "ctrl+n" and ."tui.select.up" == ["up", "ctrl+p"] and ."tui.select.down" == ["down", "ctrl+n"] and ."app.editor.external" == "ctrl+g"' "${AGENT}/keybindings.json"
}

# --- settings ---

@test "the agent directory and its settings are created when absent" {
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ "$(jq -r .theme "${AGENT}/settings.json")" = "dark" ]
    [ "$(jq -r .provider "${AGENT}/web-search.json")" = "searxng" ]
}

@test "keys pi wrote itself survive the merge" {
    mkdir -p "${AGENT}"
    echo '{ "lastChangelogVersion": "1.1.0", "theme": "light" }' > "${AGENT}/settings.json"
    echo '{ "curator": false }' > "${AGENT}/web-search.json"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ "$(jq -r .lastChangelogVersion "${AGENT}/settings.json")" = "1.1.0" ]
    [ "$(jq -r .theme "${AGENT}/settings.json")" = "dark" ]
    [ "$(jq -r .curator "${AGENT}/web-search.json")" = "false" ]
    [ "$(jq -r .provider "${AGENT}/web-search.json")" = "searxng" ]
}

@test "nested objects merge instead of being replaced" {
    mkdir -p "${AGENT}"
    echo '{ "fetch": { "defaultMode": "raw" } }' > "${AGENT}/web-search.json"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ "$(jq -r .fetch.defaultMode "${AGENT}/web-search.json")" = "raw" ]
    [ "$(jq -r .fetch.timeout "${AGENT}/web-search.json")" = "30" ]
}

@test "this host's file wins over the common one" {
    echo '{ "theme": "solarized" }' > "${FAKE}/pi/settings.testhost.json"
    echo '{ "provider": "exa" }' > "${FAKE}/pi/web-search.testhost.json"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ "$(jq -r .theme "${AGENT}/settings.json")" = "solarized" ]
    [ "$(jq -r .provider "${AGENT}/web-search.json")" = "exa" ]
}

@test "another host's file is ignored" {
    echo '{ "theme": "solarized" }' > "${FAKE}/pi/settings.otherhost.json"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ "$(jq -r .theme "${AGENT}/settings.json")" = "dark" ]
}

@test "PI_CODING_AGENT_DIR moves the agent directory, as it does for pi" {
    export PI_CODING_AGENT_DIR="${BATS_TEST_TMPDIR}/agent"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ "$(jq -r .theme "${PI_CODING_AGENT_DIR}/settings.json")" = "dark" ]
    [ ! -e "${AGENT}/settings.json" ]
}

# --- packages ---

@test "every package the repository declares is installed, in either form" {
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ "$(pi_calls)" = "$(printf 'install npm:pi-alpha@1.0.0\ninstall npm:@scope/pi-beta@2.0.0')" ]
}

@test "packages are installed into the agent directory pi is told about" {
    export PI_CODING_AGENT_DIR="${BATS_TEST_TMPDIR}/agent"
    cat > "${FAKE_BIN}/pi" <<'EOF'
#!/bin/bash
echo "${PI_CODING_AGENT_DIR}" >> "${PI_LOG}"
EOF
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ "$(sort -u "${PI_LOG}")" = "${PI_CODING_AGENT_DIR}" ]
}

@test "one package failing to install does not stop the others" {
    export PI_FAIL=pi-alpha
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [[ $output == *"npm:pi-alpha@1.0.0"* ]]
    pi_calls | grep -qx 'install npm:@scope/pi-beta@2.0.0'
}

@test "without pi the settings are still merged and installing is skipped" {
    rm "${FAKE_BIN}/pi"
    PATH="${FAKE_BIN}:/usr/bin:/bin"
    command -v pi && skip "a real pi is on /usr/bin or /bin"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [[ $output == *pi* ]]
    [ "$(jq -r .theme "${AGENT}/settings.json")" = "dark" ]
}

# --- resources written here ---
#
# Extensions, themes and prompt templates kept under pi/ are linked one entry at
# a time. The directories themselves are not links: herdr and moshi-hook put
# their own extensions next to ours, and /settings-made themes must not end up
# in the repository.

resources() {
    mkdir -p "${FAKE}/pi/extensions/gate" "${FAKE}/pi/themes" "${FAKE}/pi/prompts"
    echo 'export default () => {}' > "${FAKE}/pi/extensions/hello.ts"
    echo 'export default () => {}' > "${FAKE}/pi/extensions/gate/index.ts"
    echo '{ "name": "night" }' > "${FAKE}/pi/themes/night.json"
    echo 'Review this' > "${FAKE}/pi/prompts/review.md"
}

@test "extensions are linked one by one, single files and directories alike" {
    resources
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ "$(readlink "${AGENT}/extensions/hello.ts")" = "${FAKE}/pi/extensions/hello.ts" ]
    [ "$(readlink "${AGENT}/extensions/gate")" = "${FAKE}/pi/extensions/gate" ]
    [ ! -L "${AGENT}/extensions" ]
}

@test "themes and prompt templates are linked too" {
    resources
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ "$(readlink "${AGENT}/themes/night.json")" = "${FAKE}/pi/themes/night.json" ]
    [ "$(readlink "${AGENT}/prompts/review.md")" = "${FAKE}/pi/prompts/review.md" ]
}

@test "what other tools put in the extensions directory is left alone" {
    resources
    mkdir -p "${AGENT}/extensions"
    echo 'herdr' > "${AGENT}/extensions/herdr-agent-state.ts"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ "$(cat "${AGENT}/extensions/herdr-agent-state.ts")" = "herdr" ]
}

@test "running again changes nothing" {
    resources
    bash "${SETUP}"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ "$(readlink "${AGENT}/extensions/gate")" = "${FAKE}/pi/extensions/gate" ]
    [ ! -e "${FAKE}/pi/extensions/gate/gate" ]
}

@test "a link left behind by something removed from pi/ is cleaned up" {
    resources
    bash "${SETUP}"
    rm "${FAKE}/pi/extensions/hello.ts" "${FAKE}/pi/themes/night.json"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ ! -L "${AGENT}/extensions/hello.ts" ]
    [ ! -L "${AGENT}/themes/night.json" ]
    [ -L "${AGENT}/extensions/gate" ]
}

@test "a broken link that points somewhere else is not ours to remove" {
    mkdir -p "${AGENT}/extensions"
    ln -s "${BATS_TEST_TMPDIR}/elsewhere.ts" "${AGENT}/extensions/elsewhere.ts"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ -L "${AGENT}/extensions/elsewhere.ts" ]
}

# --- user instructions ---

@test "Claude Code's user instructions are what pi reads too" {
    mkdir -p "${HOME}/.claude"
    echo '常に日本語で会話する' > "${HOME}/.claude/CLAUDE.md"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ -L "${AGENT}/CLAUDE.md" ]
    [ "$(readlink "${AGENT}/CLAUDE.md")" = "${HOME}/.claude/CLAUDE.md" ]
}

@test "nothing is linked when there are no Claude Code instructions" {
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ ! -e "${AGENT}/CLAUDE.md" ] && [ ! -L "${AGENT}/CLAUDE.md" ]
}

@test "instructions written for pi itself are left alone" {
    mkdir -p "${HOME}/.claude" "${AGENT}"
    echo 'claude' > "${HOME}/.claude/CLAUDE.md"
    echo 'pi only' > "${AGENT}/AGENTS.md"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ ! -e "${AGENT}/CLAUDE.md" ] && [ ! -L "${AGENT}/CLAUDE.md" ]
    [ "$(cat "${AGENT}/AGENTS.md")" = "pi only" ]
}

@test "a CLAUDE.md that is a real file in the agent directory is not replaced" {
    mkdir -p "${HOME}/.claude" "${AGENT}"
    echo 'claude' > "${HOME}/.claude/CLAUDE.md"
    echo 'pi only' > "${AGENT}/CLAUDE.md"
    run bash "${SETUP}"
    [ "$status" -eq 0 ]
    [ ! -L "${AGENT}/CLAUDE.md" ]
    [ "$(cat "${AGENT}/CLAUDE.md")" = "pi only" ]
}

# --- what the repository ships ---

@test "every package the repository ships is pinned to a version" {
    run jq -r '.packages[] | if type == "string" then . else .source end' "${REPO}/pi/settings.json"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    while read -r source; do
        [[ ${source} =~ ^npm:@?[^@]+@[0-9][^@]*$ ]] || { echo "unpinned: ${source}"; return 1; }
    done <<< "$output"
}

@test "every host's theme is one the repository ships, under its own name" {
    for f in "${REPO}"/pi/settings*.json; do
        theme=$(jq -r '.theme // empty' "$f")
        [ -n "${theme}" ] || continue
        [ -f "${REPO}/pi/themes/${theme}.json" ] || { echo "$f: ${theme}"; return 1; }
    done
    for f in "${REPO}"/pi/themes/*.json; do
        [ "$(jq -r .name "$f")" = "$(basename "$f" .json)" ] || { echo "$f"; return 1; }
    done
}

@test "each host gets the palette its terminal and Claude Code use" {
    [ "$(jq -r .theme "${REPO}/pi/settings.json")" = "solarized" ]
    [ "$(jq -r .theme "${REPO}/pi/settings.anietta.json")" = "gruvbox" ]
    [ "$(jq -r .theme "${REPO}/pi/settings.boucherie.json")" = "tokyonight" ]
}

@test "the themes are valid for the pi that is pinned" {
    require node
    rm "${FAKE_BIN}/pi"
    command -v pi > /dev/null || skip "pi is not installed"
    # pi is dist/bundle/cli.js inside its package.
    local pi_root
    pi_root=$(cd "$(dirname "$(readlink -f "$(command -v pi)")")/../.." && pwd)
    run node --input-type=module -e '
        const root = process.argv[1];
        const { validateThemeJson } = await import(root + "/dist/modes/interactive/theme/theme-json.js");
        const fs = await import("node:fs");
        for (const f of process.argv.slice(2)) validateThemeJson(f, JSON.parse(fs.readFileSync(f, "utf8")));
    ' "${pi_root}" "${REPO}"/pi/themes/*.json
    [ "$status" -eq 0 ]
}

@test "web search goes to the fleet's SearXNG and nowhere else" {
    local f="${REPO}/pi/web-search.json"
    [ "$(jq -r .provider "$f")" = "searxng" ]
    [ "$(jq -r .searxngBaseUrl "$f")" = "http://searxng.searxng.svc.fraction.cluster" ]
}

@test "the SearXNG service range is let through pi-web-access's SSRF guard" {
    jq -e '.ssrf.allowRanges == ["10.254.0.0/24"]' "${REPO}/pi/web-search.json"
}

@test "fetching falls back from a local fetch to Jina Reader only" {
    jq -e '.fetchRouting.providers == ["http", "jina"]' "${REPO}/pi/web-search.json"
    jq -e '.fetchRouting.allowRemoteHostedProviders == true' "${REPO}/pi/web-search.json"
}

@test "setup.sh runs setup-pi.sh and wires pi into herdr" {
    grep -q 'setup-pi.sh' "${REPO}/bin/setup.sh"
    grep -Eq '^ *for target in .*\bpi\b.*; do' "${REPO}/bin/setup.sh"
}

@test "renovate reads the package pins in pi/settings.json" {
    require node
    run node -e '
        const fs = require("fs");
        const cfg = JSON.parse(fs.readFileSync(process.argv[1] + "/renovate.json", "utf8"));
        const m = cfg.customManagers.find(m => m.managerFilePatterns.includes("pi/settings.json"));
        if (!m) { console.error("no manager"); process.exit(1); }
        const text = fs.readFileSync(process.argv[1] + "/pi/settings.json", "utf8");
        const found = [];
        for (const s of m.matchStrings) {
            for (const g of text.matchAll(new RegExp(s, "g"))) found.push(`${g.groups.depName}@${g.groups.currentValue}`);
        }
        if (m.datasourceTemplate !== "npm") { console.error("datasource"); process.exit(1); }
        console.log(found.sort().join("\n"));
    ' "${REPO}"
    [ "$status" -eq 0 ]
    expected=$(jq -r '.packages[] | if type == "string" then . else .source end | sub("^npm:"; "")' "${REPO}/pi/settings.json" | sort)
    [ "$output" = "$expected" ]
}
