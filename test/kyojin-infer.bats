#!/usr/bin/env bats

@test "fixed Kyojin acquisition contracts (offline)" {
  run python3 "$BATS_TEST_DIRNAME/kyojin_infer_download_test.py"
  [ "$status" -eq 0 ]
}

@test "Kyojin inference scoring and lifecycle contracts (offline)" {
  run python3 "$BATS_TEST_DIRNAME/kyojin_infer_test.py"
  [ "$status" -eq 0 ]
}
