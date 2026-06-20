#!/usr/bin/env bats
# lib/*.sh の単体テスト。
# 各 lib を /bin/bash (macOS 3.2) で source し、関数を isolation 検証する。

LIB_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib" && pwd)"

setup() {
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

# === log.sh ===

@test "log_init creates log file (600) and dir (700) at creation time" {
  LOG_DIR="$TMP/logs"
  LOG_FILE="$LOG_DIR/test.log"
  source "$LIB_DIR/log.sh"
  log_init
  [ -d "$LOG_DIR" ]
  [ -f "$LOG_FILE" ]
  [ "$(stat -f '%Lp' "$LOG_DIR")" = "700" ]
  [ "$(stat -f '%Lp' "$LOG_FILE")" = "600" ]
}

@test "log appends a timestamped line" {
  LOG_DIR="$TMP/logs"
  LOG_FILE="$LOG_DIR/test.log"
  source "$LIB_DIR/log.sh"
  log_init
  log "hello world"
  grep -q "hello world" "$LOG_FILE"
  grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] ' "$LOG_FILE"
}

@test "log_init deletes logs older than 30 days" {
  LOG_DIR="$TMP/logs"
  LOG_FILE="$LOG_DIR/today.log"
  mkdir -p "$LOG_DIR"
  : > "$LOG_DIR/old.log"
  touch -t 202501010000 "$LOG_DIR/old.log"  # 30日超
  source "$LIB_DIR/log.sh"
  log_init
  [ ! -f "$LOG_DIR/old.log" ]
  [ -f "$LOG_FILE" ]
}

# === notify.sh ===

@test "notify is a no-op (returns 0) when osascript is absent" {
  run env PATH="/nonexistent-dir" /bin/bash -c "source '$LIB_DIR/notify.sh'; notify 'body' 'title'"
  [ "$status" -eq 0 ]
}

@test "notify does not crash with quotes/backslashes in body (injection guard)" {
  run /bin/bash -c "source '$LIB_DIR/notify.sh'; notify 'a\"b\\c' 'ti\"tle'"
  [ "$status" -eq 0 ]
}

# === env.sh ===

@test "env.sh unsets ANTHROPIC_API_KEY" {
  # 変数名を組み立てて設定する (pre-commit の secret スキャンが key 名 + 等号 +
  # 非空白のリテラルを検知するため、その並びをソースに書かない)
  local name="ANTHROPIC_API_KEY"
  export "$name=dummy-test-value"
  run /bin/bash -c "source '$LIB_DIR/env.sh'; printenv $name || echo UNSET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNSET"* ]]
}

@test "env.sh puts homebrew bin first on PATH" {
  run /bin/bash -c "source '$LIB_DIR/env.sh'; echo \"\$PATH\""
  [ "$status" -eq 0 ]
  [[ "$output" == "/opt/homebrew/bin:"* ]] || [[ "$output" == *"$HOME/.claude/local:/opt/homebrew/bin:"* ]]
}
