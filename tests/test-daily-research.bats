#!/usr/bin/env bats
# Public command contracts; no model calls.
setup() {
  PROJECT_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$PROJECT_DIR/scripts/daily-research.sh"
}
@test "entrypoints have valid Bash syntax" {
  bash -n "$SCRIPT"
  bash -n "$PROJECT_DIR/scripts/check-auth.sh"
}
@test "help exposes preview and config without starting a job" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--preview"* ]]
  [[ "$output" == *"--config"* ]]
}
@test "unknown option fails before research" {
  run bash "$SCRIPT" --not-an-option
  [ "$status" -eq 64 ]
}
@test "invalid date fails before research" {
  run bash "$SCRIPT" --date 2026-02-30
  [ "$status" -eq 64 ]
}
@test "backdated live writes require preview" {
  run bash "$SCRIPT" --date 2000-01-01
  [ "$status" -eq 64 ]
  [[ "$output" == *"--preview"* ]]
}
@test "launchd template uses unchanged entrypoint" {
  run plutil -lint "$PROJECT_DIR/com.example.daily-research.plist"
  [ "$status" -eq 0 ]
  grep -q daily-research.sh "$PROJECT_DIR/com.example.daily-research.plist"
}
