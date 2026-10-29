#!/usr/bin/env bats
#
# pi/extensions/vuln-tracker。中身は node --test の単体テスト (test/pi-vuln-tracker.test.ts)。

load helpers

@test "the vuln-tracker extension passes its unit tests" {
    require node
    # .ts をそのまま読める (type stripping) 版が要る。
    node -e 'process.exit(process.features.typescript ? 0 : 1)' 2> /dev/null ||
        skip "node cannot run TypeScript directly"
    run node --test "${REPO}/test/pi-vuln-tracker.test.ts"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "the vuln_tracker_findings output schema lets unknown keys and values through" {
    require node
    require pi
    node -e 'process.exit(process.features.typescript ? 0 : 1)' 2> /dev/null ||
        skip "node cannot run TypeScript directly"
    # index.ts は pi が読み込むときに pi 同梱の typebox を使う。テストでも同じものを横に置く。
    pkg=$(readlink -f "$(command -v pi)")
    while [ "${pkg}" != / ] && [ "$(basename "${pkg}")" != pi-coding-agent ]; do
        pkg=$(dirname "${pkg}")
    done
    [ -d "${pkg}/node_modules/typebox" ] || skip "typebox is not found next to pi"
    ext="${BATS_TEST_TMPDIR}/vuln-tracker"
    cp -R "${REPO}/pi/extensions/vuln-tracker" "${ext}"
    mkdir "${ext}/node_modules"
    ln -s "${pkg}/node_modules/typebox" "${ext}/node_modules/typebox"
    VULN_TRACKER_EXTENSION="${ext}" run node --test "${REPO}/test/pi-vuln-tracker-schema.test.ts"
    echo "$output"
    [ "$status" -eq 0 ]
}
