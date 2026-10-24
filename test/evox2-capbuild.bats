#!/usr/bin/env bats

@test "capped build supervisor offline lifecycle and safety fixtures" {
  run python3 "$BATS_TEST_DIRNAME/evox2_capbuild_test.py"
  [ "$status" -eq 0 ]
}
