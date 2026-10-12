#!/usr/bin/env bats

load helpers

setup() {
    require jq
    export HOME="${BATS_TEST_TMPDIR}/home.test+[user]"
    unset PI_CODING_AGENT_DIR
    AGENT="$HOME/.pi/agent"
    TARGET="$AGENT/extensions/pi-automode/config.json"
    LEGACY="$AGENT/config/pi-verdict.json"
    FAKE="${BATS_TEST_TMPDIR}/checkout"
    mkdir -p "$FAKE/bin" "$FAKE/pi/config" "$AGENT/config" "${BATS_TEST_TMPDIR}/bin"
    cp "${REPO}/bin/setup-pi.sh" "${REPO}/bin/herdr-task-worktree" "$FAKE/bin/"
    cp "${REPO}/pi/"*.json "$FAKE/pi/"
    cp "${REPO}/pi/config/pi-automode.json" "$FAKE/pi/config/"
    printf '#!/bin/sh\nexit 0\n' > "${BATS_TEST_TMPDIR}/bin/pi"
    printf '#!/bin/sh\necho testhost\n' > "${BATS_TEST_TMPDIR}/bin/hostname"
    chmod +x "${BATS_TEST_TMPDIR}/bin/"*
    export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
}

@test "automode policy uses default classification without broad shell exemptions" {
    run bash "$FAKE/bin/setup-pi.sh"
    [ "$status" -eq 0 ]
    [ ! -L "$TARGET" ]
    jq -e --arg home "$HOME" '.autoMode.enabled and (.autoMode.classifyReadOnlyTools | not) and (.autoMode.allowInsideWorkingDirectory | not) and .permissions.allow[0] == "web_enable" and (.permissions.allow | index("bash(" + $home + "/bin/herdr-task-worktree *)") != null and all(contains("__HOME__") | not)) and .autoMode.hard_deny == ["$defaults"] and .autoMode.soft_deny == ["$defaults"]' "$TARGET"
    jq -e '.autoMode.deniedPaths | index("~/.ssh") != null and index("~/.ssh/*") != null' "$TARGET"
    jq -e '.autoMode.allow[0] == "$defaults" and (.autoMode.allow[1:] | any(test("tracked by git")))' "$TARGET"
    [ -x "$HOME/bin/herdr-task-worktree" ]
    cp "$TARGET" "${BATS_TEST_TMPDIR}/before.json"
    run bash "$FAKE/bin/setup-pi.sh"
    [ "$status" -eq 0 ]
    cmp "$TARGET" "${BATS_TEST_TMPDIR}/before.json"
}

@test "setup replaces verdict declaration and retains legacy protected paths without editing legacy config" {
    echo '{"packages":["npm:pi-verdict@0.15.0"],"lastChangelogVersion":"local"}' > "$AGENT/settings.json"
    echo '{"allow":["old-regex"],"deny":[],"denyPaths":["~/private/","~/.local-secret"],"ignoreTools":["custom-tool"],"classifierModel":"typesafe/jev-latest"}' > "$LEGACY"
    cp "$LEGACY" "${BATS_TEST_TMPDIR}/legacy.json"
    run bash "$FAKE/bin/setup-pi.sh"
    [ "$status" -eq 0 ]
    cmp "$LEGACY" "${BATS_TEST_TMPDIR}/legacy.json"
    jq -e '.autoMode.deniedPaths | index("~/private") != null and index("~/private/*") != null and index("~/.local-secret") != null' "$TARGET"
    jq -e --arg home "$HOME" --slurpfile common "$FAKE/pi/config/pi-automode.json" '.permissions.allow == ($common[0].permissions.allow | map(split("__HOME__") | join($home))) and .autoMode.classifierModel == $common[0].autoMode.classifierModel' "$TARGET"
    jq -e '.lastChangelogVersion == "local" and (.packages | any(startswith("npm:@czottmann/pi-automode@"))) and (.packages | any(startswith("npm:pi-verdict")) | not)' "$AGENT/settings.json"
}

@test "untranslated legacy deny rules stop first migration before package changes" {
    echo '{"packages":["npm:pi-verdict@0.15.0"]}' > "$AGENT/settings.json"
    cp "$AGENT/settings.json" "${BATS_TEST_TMPDIR}/before.json"
    echo '{"deny":["local-deny"]}' > "$LEGACY"
    run bash "$FAKE/bin/setup-pi.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"deny を手動で移行"* ]]
    [ ! -e "$TARGET" ]
    cmp "$AGENT/settings.json" "${BATS_TEST_TMPDIR}/before.json"
}

@test "invalid automode JSON stops migration without changing package declarations" {
    echo '{"packages":["npm:pi-verdict@0.15.0"]}' > "$AGENT/settings.json"
    cp "$AGENT/settings.json" "${BATS_TEST_TMPDIR}/before.json"
    echo 'invalid-json' > "$FAKE/pi/config/pi-automode.testhost.json"
    run bash "$FAKE/bin/setup-pi.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"マージに失敗"* ]]
    cmp "$AGENT/settings.json" "${BATS_TEST_TMPDIR}/before.json"
}

@test "local protections survive while common and host choose the classifier" {
    mkdir -p "$(dirname "$TARGET")"
    echo '{"autoMode":{"classifierModel":"local/model","deniedPaths":["~/private/*"],"hard_deny":["local policy"],"soft_deny":["local soft policy"],"protectedPaths":["local-control"],"allow":["local allow"]},"permissions":{"deny":["bash(local*)"],"ask":["bash(review*)"],"allow":["old"]}}' > "$TARGET"
    echo '{"autoMode":{"classifierReasoningLevel":"low","deniedPaths":["~/host/*"],"hard_deny":["host policy"]},"permissions":{"deny":["bash(host*)"],"ask":["bash(host-review*)"]}}' > "$FAKE/pi/config/pi-automode.testhost.json"
    run bash "$FAKE/bin/setup-pi.sh"
    [ "$status" -eq 0 ]
    jq -e --slurpfile common "$FAKE/pi/config/pi-automode.json" '.autoMode.classifierModel == $common[0].autoMode.classifierModel and .autoMode.classifierReasoningLevel == "low" and (.autoMode.deniedPaths | index("~/private/*") != null and index("~/host/*") != null) and (.autoMode.hard_deny | index("local policy") != null and index("host policy") != null and index("$defaults") != null) and (.autoMode.soft_deny | index("local soft policy") != null) and (.autoMode.protectedPaths | index("local-control") != null)' "$TARGET"
    jq -e '.permissions.deny == ["bash(host*)", "bash(local*)"] and .permissions.ask == ["bash(host-review*)", "bash(review*)"]' "$TARGET"
    jq -e --arg home "$HOME" --slurpfile common "$FAKE/pi/config/pi-automode.json" '.permissions.allow == ($common[0].permissions.allow | map(split("__HOME__") | join($home)))' "$TARGET"
    jq -e --slurpfile common "$FAKE/pi/config/pi-automode.json" '.autoMode.allow == $common[0].autoMode.allow' "$TARGET"
    echo '{"autoMode":{"classifierModel":"host/model"}}' > "$FAKE/pi/config/pi-automode.testhost.json"
    run bash "$FAKE/bin/setup-pi.sh"
    [ "$status" -eq 0 ]
    jq -e '.autoMode.classifierModel == "host/model" and (.autoMode.hard_deny | index("host policy") != null)' "$TARGET"
}

@test "automode uses its upstream fixed HOME config path even with a custom agent directory" {
    export PI_CODING_AGENT_DIR="${BATS_TEST_TMPDIR}/custom-agent"
    run bash "$FAKE/bin/setup-pi.sh"
    [ "$status" -eq 0 ]
    [ -f "$TARGET" ]
    [ -f "$PI_CODING_AGENT_DIR/settings.json" ]
    [ ! -e "$PI_CODING_AGENT_DIR/extensions/pi-automode/config.json" ]
}
