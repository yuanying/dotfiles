#!/usr/bin/env bats

@test "CPU load runner offline fixtures" {
  run python3 "$BATS_TEST_DIRNAME/evox2_cpu_load_test.py"
  [ "$status" -eq 0 ]
}
