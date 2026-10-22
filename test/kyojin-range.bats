#!/usr/bin/env bats

load helpers

@test "Kyojin Range metadata uses bounded offline fixtures" {
    run python3 "${REPO}/test/kyojin_range_test.py"
    [ "$status" -eq 0 ]
}

@test "Kyojin SDK read budget override is source-pinned and narrowly scoped" {
    run python3 "${REPO}/test/kyojin_sdk_budget_test.py"
    [ "$status" -eq 0 ]
}
