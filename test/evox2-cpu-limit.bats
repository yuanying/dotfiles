#!/usr/bin/env bats

@test "Evo-X2 temporary CPU limit offline fixtures" {
  run python3 "$BATS_TEST_DIRNAME/evox2_cpu_limit_test.py"
  [ "$status" -eq 0 ]
}
