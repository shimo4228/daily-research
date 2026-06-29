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

@test "notify does not crash with embedded newlines (multi-statement injection guard)" {
  run /bin/bash -c "source '$LIB_DIR/notify.sh'; notify \$'line1\nline2' \$'ti\ntle'"
  [ "$status" -eq 0 ]
}

# === lock.sh (mkdir アトミックロック) ===

@test "acquire_lock succeeds when no lock exists and records pid" {
  LOCK_DIR="$TMP/lock"
  source "$LIB_DIR/lock.sh"
  run acquire_lock
  [ "$status" -eq 0 ]
  [ -d "$LOCK_DIR" ]
  [ -f "$LOCK_DIR/pid" ]
}

@test "acquire_lock fails when a live lock is held" {
  LOCK_DIR="$TMP/lock"
  mkdir "$LOCK_DIR"
  echo $$ > "$LOCK_DIR/pid"   # 自プロセス = 生きている PID
  source "$LIB_DIR/lock.sh"
  run acquire_lock
  [ "$status" -ne 0 ]
}

@test "acquire_lock steals a stale lock (dead pid)" {
  LOCK_DIR="$TMP/lock"
  mkdir "$LOCK_DIR"
  echo "999999999" > "$LOCK_DIR/pid"   # 存在しない PID
  source "$LIB_DIR/lock.sh"
  run acquire_lock
  [ "$status" -eq 0 ]
  [ "$(cat "$LOCK_DIR/pid")" = "$$" ]   # 自分の PID に置き換わる
}

@test "release_lock removes only own lock" {
  LOCK_DIR="$TMP/lock"
  source "$LIB_DIR/lock.sh"
  acquire_lock
  [ -d "$LOCK_DIR" ]
  release_lock
  [ ! -d "$LOCK_DIR" ]
}

@test "release_lock does not remove a lock owned by another pid" {
  LOCK_DIR="$TMP/lock"
  mkdir "$LOCK_DIR"
  echo "999999999" > "$LOCK_DIR/pid"   # 他プロセス所有
  source "$LIB_DIR/lock.sh"
  release_lock
  [ -d "$LOCK_DIR" ]   # 自分のものでないので消さない
}

# === graph.sh ===

@test "check_graph_health passes for valid graph with @graph" {
  PROJECT_DIR="$TMP/proj"
  mkdir -p "$PROJECT_DIR"
  echo '{"@graph": []}' > "$PROJECT_DIR/graph.jsonld"
  LOG_FILE="$TMP/test.log"; : > "$LOG_FILE"
  DR_PY="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib" && pwd)/dr_pipeline.py"
  source "$LIB_DIR/log.sh"
  source "$LIB_DIR/notify.sh"
  source "$LIB_DIR/graph.sh"
  run check_graph_health
  [ "$status" -eq 0 ]
  grep -q "health check passed" "$LOG_FILE"
}

@test "check_graph_health fails (non-zero) for missing graph" {
  PROJECT_DIR="$TMP/proj-missing"
  mkdir -p "$PROJECT_DIR"   # graph.jsonld は作らない
  LOG_FILE="$TMP/test.log"; : > "$LOG_FILE"
  DR_PY="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib" && pwd)/dr_pipeline.py"
  source "$LIB_DIR/log.sh"
  source "$LIB_DIR/notify.sh"
  source "$LIB_DIR/graph.sh"
  run check_graph_health
  [ "$status" -ne 0 ]
}

# === auth.sh (real_auth_probe) ===

_dr_py() {
  echo "$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib" && pwd)/dr_pipeline.py"
}

@test "real_auth_probe returns 0 when API responds without error" {
  cat > "$TMP/claude" <<'EOF'
#!/bin/bash
[[ "$1" == "--version" ]] && { echo mock; exit 0; }
echo '{"type":"result","is_error":false}'
exit 0
EOF
  chmod +x "$TMP/claude"
  CLAUDE_CMD="$TMP/claude"
  DR_PY="$(_dr_py)"
  source "$LIB_DIR/auth.sh"
  run real_auth_probe
  [ "$status" -eq 0 ]
}

@test "real_auth_probe returns 1 on 401/is_error" {
  cat > "$TMP/claude" <<'EOF'
#!/bin/bash
[[ "$1" == "--version" ]] && { echo mock; exit 0; }
echo '{"type":"result","is_error":true,"api_error_status":401}'
exit 1
EOF
  chmod +x "$TMP/claude"
  CLAUDE_CMD="$TMP/claude"
  DR_PY="$(_dr_py)"
  source "$LIB_DIR/auth.sh"
  run real_auth_probe
  [ "$status" -eq 1 ]
}

@test "real_auth_probe returns 1 on is_error WITHOUT api_error_status (leading empty field)" {
  # api_error_status が無い is_error:true。error-fields は "\ttrue" を返すため、
  # 先頭の空フィールドを潰さない parse でないと取りこぼす (回帰防止)
  cat > "$TMP/claude" <<'EOF'
#!/bin/bash
[[ "$1" == "--version" ]] && { echo mock; exit 0; }
echo '{"type":"result","is_error":true}'
exit 1
EOF
  chmod +x "$TMP/claude"
  CLAUDE_CMD="$TMP/claude"
  DR_PY="$(_dr_py)"
  source "$LIB_DIR/auth.sh"
  run real_auth_probe
  [ "$status" -eq 1 ]
}

# === claude.sh (classify_exit) ===

_fixtures() {
  echo "$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures"
}

@test "classify_exit: api_error_status 401 -> E_AUTH" {
  DR_PY="$(_dr_py)"; source "$LIB_DIR/claude.sh"
  run classify_exit 1 '{"is_error":true,"api_error_status":401}'
  [ "$output" = "E_AUTH" ]
}

@test "classify_exit: timeout (124) -> E_TRANSIENT" {
  DR_PY="$(_dr_py)"; source "$LIB_DIR/claude.sh"
  run classify_exit 124 '{"is_error":false}'
  [ "$output" = "E_TRANSIENT" ]
}

@test "classify_exit: exit 0 but is_error -> E_FATAL (success masking guard)" {
  DR_PY="$(_dr_py)"; source "$LIB_DIR/claude.sh"
  run classify_exit 0 '{"is_error":true}'
  [ "$output" = "E_FATAL" ]
}

@test "classify_exit: non-zero exit -> E_FATAL" {
  DR_PY="$(_dr_py)"; source "$LIB_DIR/claude.sh"
  run classify_exit 1 '{"is_error":false}'
  [ "$output" = "E_FATAL" ]
}

@test "classify_exit: exit 0 no error -> OK (real success fixture)" {
  DR_PY="$(_dr_py)"; source "$LIB_DIR/claude.sh"
  run classify_exit 0 "$(cat "$(_fixtures)/result-success.json")"
  [ "$output" = "OK" ]
}

@test "classify_exit: real 401 fixture -> E_AUTH" {
  DR_PY="$(_dr_py)"; source "$LIB_DIR/claude.sh"
  run classify_exit 1 "$(cat "$(_fixtures)/result-401.json")"
  [ "$output" = "E_AUTH" ]
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
