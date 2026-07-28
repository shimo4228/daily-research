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

@test "all 3 entrypoints share real_auth_probe (no formalized --version auth)" {
  # auth-002: check-auth.sh は本 flow に未配線だった。lib/auth.sh で正本化し 3 つが共有
  grep -q 'real_auth_probe' "$SCRIPT"
  grep -q 'real_auth_probe' "$PROJECT_DIR/scripts/check-auth.sh"
  grep -q 'real_auth_probe' "$PROJECT_DIR/scripts/bootstrap-graph.sh"
  # 形骸化した「--version で認証確認」が残っていない
  ! grep -qi 'version.*authentication\|authentication.*version' "$PROJECT_DIR/scripts/check-auth.sh"
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

@test "daily-research.sh injects cluster saturation report into Pass 1 prompt" {
  # 自由探索ラインの cluster 反発 (旧 tech track の固定 domains 飽和の再発防止)
  grep -q 'CLUSTER' "$SCRIPT"
  grep -q 'cluster-report' "$SCRIPT"
}

@test "theme-selection-prompt forbids reusing the same primary source" {
  grep -q "ソース単位の重複禁止" "$PROJECT_DIR/prompts/theme-selection-prompt.md"
}

@test "theme-selection-prompt documents coverage/frontier/explore modes" {
  grep -q "frontier" "$PROJECT_DIR/prompts/theme-selection-prompt.md"
  grep -q "explore" "$PROJECT_DIR/prompts/theme-selection-prompt.md"
  grep -q "常設フロンティア質問" "$PROJECT_DIR/prompts/theme-selection-prompt.md"
}

@test "platform digest prompt and template contract is explicit" {
  grep -q 'platform_digest' "$PROJECT_DIR/prompts/research-protocol.md"
  grep -q 'platform_digest' "$PROJECT_DIR/prompts/theme-selection-prompt.md"
  grep -q '今日の探索アングル' "$PROJECT_DIR/templates/report-template.md"
  grep -q '総評' "$PROJECT_DIR/templates/report-template.md"
  grep -q 'PILOT | WATCH | DROP' "$PROJECT_DIR/templates/report-template.md"
  grep -q '実活動' "$PROJECT_DIR/prompts/research-protocol.md"
}

@test "coverage-report emits per-repo MODE judgement" {
  run "$PROJECT_DIR/scripts/coverage-report.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MODE:"* ]]
  [[ "$output" == *"Line:"* ]]
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

@test "env.sh source declares unset ANTHROPIC_API_KEY (static)" {
  # 環境サニタイズは lib/env.sh に集約 (S3)。挙動テストは test-lib.bats 側
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

# === 自己改善ループの計測 (ADR-0006) ===

@test "daily-research.sh wires metrics collection non-fatally" {
  grep -q 'metrics-append' "$SCRIPT"
  grep -q 'report-lint' "$SCRIPT"
  grep -q 'review-age' "$SCRIPT"
  # 収集失敗が生成ジョブの成否 (FINAL_EXIT) を変えない non-fatal ガード
  grep -q 'WARN: metrics-append failed (non-fatal)' "$SCRIPT"
  # metrics-append は FINAL_EXIT 確定後 (exit 直前) に置かれている
  awk '/metrics-append/{m=NR} /^exit "\$FINAL_EXIT"/{e=NR} END{exit !(m && e && m<e)}' "$SCRIPT"
}

@test "metrics.jsonl is gitignored (personal cost data, public repo)" {
  grep -qx 'metrics.jsonl' "$PROJECT_DIR/.gitignore"
}
