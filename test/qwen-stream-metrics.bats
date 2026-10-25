#!/usr/bin/env bats

@test "Qwen SSE arrival metrics and preflight fixtures (offline)" {
  run python3 "$BATS_TEST_DIRNAME/qwen_stream_metrics_test.py"
  [ "$status" -eq 0 ]
}
