#!/usr/bin/env bats
#
# pi/extensions/gofmt.ts。中身は node --test の単体テスト (test/pi-gofmt.test.ts)。

load helpers

@test "the gofmt extension passes its unit tests" {
    require node
    require gofmt
    # .ts をそのまま読める (type stripping) 版が要る。
    node -e 'process.exit(process.features.typescript ? 0 : 1)' 2> /dev/null ||
        skip "node cannot run TypeScript directly"
    run node --test "${REPO}/test/pi-gofmt.test.ts"
    echo "$output"
    [ "$status" -eq 0 ]
}
