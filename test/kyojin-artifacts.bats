#!/usr/bin/env bats

@test "Kyojin artifact verifier offline fixtures" {
  run python3 "$BATS_TEST_DIRNAME/kyojin_artifacts_test.py"
  [ "$status" -eq 0 ]
}
