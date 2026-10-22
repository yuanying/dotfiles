#!/usr/bin/env bats

@test "Kyojin SDK deployment containment fixtures" {
  run python3 "$BATS_TEST_DIRNAME/kyojin_trial_test.py"
  [ "$status" -eq 0 ]
}

@test "Qwen live SSE adapter fixtures" {
  run python3 "$BATS_TEST_DIRNAME/qwen_stream_live_test.py"
  [ "$status" -eq 0 ]
}

@test "Qwen safety guard fixtures" {
  run python3 "$BATS_TEST_DIRNAME/qwen_trial_guard_test.py"
  [ "$status" -eq 0 ]
}
