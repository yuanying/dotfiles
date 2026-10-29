#!/usr/bin/env bats
#
# pi/extensions/release-lag。中身は node --test の単体テスト (test/pi-release-lag.test.ts)。

load helpers

@test "the release-lag extension passes its unit tests" {
    require node
    # .ts をそのまま読める (type stripping) 版が要る。
    node -e 'process.exit(process.features.typescript ? 0 : 1)' 2> /dev/null ||
        skip "node cannot run TypeScript directly"
    run node --test "${REPO}/test/pi-release-lag.test.ts"
    echo "$output"
    [ "$status" -eq 0 ]
}
