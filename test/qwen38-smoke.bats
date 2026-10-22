#!/usr/bin/env bats

load helpers

@test "qwen38 offline request and response regression tests" {
    run python3 "${REPO}/test/qwen38_smoke_test.py"
    [ "$status" -eq 0 ]
}
