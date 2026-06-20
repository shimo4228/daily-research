#!/usr/bin/env bats
# Tests for daily-research project
# Run: bats tests/test-daily-research.bats

# テストファイルからの相対パスでプロジェクトルートを解決
PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
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

@test "coverage-report.sh has valid syntax" {
  bash -n "$PROJECT_DIR/scripts/coverage-report.sh"
}

# === Theme dedup (重複テーマ防止) ===

@test "coverage-report shows reinforcing source history" {
  run "$PROJECT_DIR/scripts/coverage-report.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"既出:"* ]]
}

@test "coverage-report lists repo ExternalReference as forbidden sources" {
  run "$PROJECT_DIR/scripts/coverage-report.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repo 取り込み済み外部文献"* ]]
}

@test "daily-research.sh injects past themes into Pass 1 prompt" {
  grep -q "過去テーマ履歴" "$SCRIPT"
  grep -q 'PAST_THEMES' "$SCRIPT"
}

@test "theme-selection-prompt forbids reusing the same primary source" {
  grep -q "ソース単位の重複禁止" "$PROJECT_DIR/prompts/theme-selection-prompt.md"
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
# acquire_lock / release_lock の振る舞いテストは tests/test-lib.bats に集約 (S4)。
# ここでは orchestrator が mkdir アトミックロックを採用していることを静的確認する。

@test "orchestrator uses mkdir-atomic lock via lib/lock.sh" {
  grep -q 'source.*lock.sh' "$SCRIPT"
  grep -q 'acquire_lock' "$SCRIPT"
  # check-then-write の旧パターン (echo \$\$ > LOCK_FILE) が残っていない
  ! grep -q 'echo \$\$ > "\$LOCK_FILE"' "$SCRIPT"
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

@test "env.sh unsets ANTHROPIC_API_KEY" {
  # 環境サニタイズは lib/env.sh に集約 (S3)
  grep -q "unset ANTHROPIC_API_KEY" "$PROJECT_DIR/scripts/lib/env.sh"
}

@test "no hardcoded API keys in script" {
  # sk- followed by 20+ alphanumeric chars (actual API key pattern)
  ! grep -qE '(sk-[a-zA-Z0-9]{20,}|api_key\s*=\s*"[^"]+")' "$SCRIPT"
}

@test "log file permissions are restricted (chmod 600)" {
  # ログ権限制限は lib/log.sh の log_init() に集約 (作成時 chmod, S3)
  grep -q 'chmod 600 "$LOG_FILE"' "$PROJECT_DIR/scripts/lib/log.sh"
}

# === Defensive programming ===

@test "set -euo pipefail is configured" {
  head -3 "$SCRIPT" | grep -q "set -euo pipefail"
}

@test "trap release_lock is registered on EXIT" {
  grep -q 'trap release_lock EXIT' "$SCRIPT"
}

@test "max-turns is configured for both passes" {
  grep -q '\-\-max-turns' "$SCRIPT"
}
