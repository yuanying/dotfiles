#!/usr/bin/env bats

load helpers

@test "the ChatGPT image extension passes its unit tests" {
    require node
    node -e 'process.exit(process.features.typescript ? 0 : 1)' 2> /dev/null ||
        skip "node cannot run TypeScript directly"
    # Run node:test directly: process-isolated --test can re-enter asdf's shim
    # and report only the file without executing its tests on some hosts.
    run node "${REPO}/test/pi-imagegen.test.ts"
    echo "$output"
    [ "$status" -eq 0 ]
}
