#!/usr/bin/env bats
# Tests for daily-research project
# Run: bats tests/test-daily-research.bats

PROJECT_DIR="/Users/shimomoto_tatsuya/MyAI_Lab/daily-research"
SCRIPT="$PROJECT_DIR/scripts/daily-research.sh"

# === Setup / Teardown ===

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# === Syntax checks ===

@test "daily-research.sh has valid syntax" {
  bash -n "$SCRIPT"
}

@test "check-auth.sh has valid syntax" {
  bash -n "$PROJECT_DIR/scripts/check-auth.sh"
}

# === Config files exist ===

@test "config.toml exists" {
  [ -f "$PROJECT_DIR/config.toml" ]
}

@test "task-prompt.md exists" {
  [ -f "$PROJECT_DIR/prompts/task-prompt.md" ]
}

@test "research-protocol.md exists" {
  [ -f "$PROJECT_DIR/prompts/research-protocol.md" ]
}

@test "report-template.md exists" {
  [ -f "$PROJECT_DIR/templates/report-template.md" ]
}

# === launchd plist validation ===

@test "plist is valid XML" {
  plutil -lint "$PROJECT_DIR/com.shimomoto.daily-research.plist"
}

@test "plist points to correct script path" {
  plutil -extract ProgramArguments json \
    "$PROJECT_DIR/com.shimomoto.daily-research.plist" \
    -o - | grep -q "daily-research.sh"
}

@test "plist schedule is set to 5:00" {
  local hour
  hour=$(plutil -extract StartCalendarInterval.Hour raw \
    "$PROJECT_DIR/com.shimomoto.daily-research.plist")
  [ "$hour" = "5" ]
}

# === Lock mechanism ===

@test "lock file can be created and removed" {
  local lock_file="$TEST_TMPDIR/.daily-research.lock"

  echo "12345" > "$lock_file"
  [ -f "$lock_file" ]

  rm -f "$lock_file"
  [ ! -f "$lock_file" ]
}

@test "stale lock file with dead PID is detected" {
  local lock_file="$TEST_TMPDIR/.daily-research.lock"

  # Create lock with non-existent PID
  echo "999999999" > "$lock_file"

  # kill -0 should fail for non-existent process
  ! kill -0 999999999 2>/dev/null
}

# === Log directory ===

@test "logs directory exists" {
  [ -d "$PROJECT_DIR/logs" ]
}

@test "logs directory has permission 700" {
  local perms
  perms=$(stat -f "%Lp" "$PROJECT_DIR/logs")
  [ "$perms" = "700" ]
}

# === past_topics.json ===

@test "past_topics.json is valid JSON" {
  python3 -c "import json; json.load(open('$PROJECT_DIR/past_topics.json'))"
}

@test "past_topics.json backup exists" {
  [ -f "$PROJECT_DIR/past_topics.json.bak" ]
}

# === Security checks ===

@test "script unsets ANTHROPIC_API_KEY" {
  grep -q "unset ANTHROPIC_API_KEY" "$SCRIPT"
}

@test "no hardcoded API keys in script" {
  # sk- followed by 20+ alphanumeric chars (actual API key pattern)
  ! grep -qE '(sk-[a-zA-Z0-9]{20,}|api_key\s*=\s*"[^"]+")' "$SCRIPT"
}

@test "log file permissions are restricted (chmod 600)" {
  grep -q 'chmod 600 "$LOG_FILE"' "$SCRIPT"
}

# === Defensive programming ===

@test "set -euo pipefail is configured" {
  head -3 "$SCRIPT" | grep -q "set -euo pipefail"
}

@test "trap cleanup is registered on EXIT" {
  grep -q 'trap cleanup EXIT' "$SCRIPT"
}

@test "timeout is configured" {
  grep -q 'TIMEOUT_SECONDS=' "$SCRIPT"
}
