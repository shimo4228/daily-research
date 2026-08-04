#!/usr/bin/env bats
# Tests for daily-research project (per-repo in-context research, ADR-0008)
# Run: bats tests/test-daily-research.bats

# テストファイルからの相対パスでプロジェクトルートを解決
PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$PROJECT_DIR/scripts/daily-research.sh"
BRIEF="$PROJECT_DIR/scripts/morning-brief.sh"

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

@test "morning-brief.sh has valid syntax" {
  bash -n "$BRIEF"
}

@test "entrypoints share real_auth_probe (no formalized --version auth)" {
  # auth-002: lib/auth.sh で正本化し共有 (bootstrap-graph.sh は ADR-0008 で retire)
  grep -q 'real_auth_probe' "$SCRIPT"
  grep -q 'real_auth_probe' "$PROJECT_DIR/scripts/check-auth.sh"
  ! grep -qi 'version.*authentication\|authentication.*version' "$PROJECT_DIR/scripts/check-auth.sh"
}

# === Per-repo 実行の配線 (ADR-0008) ===

@test "orchestrator loops lines via tracks and runs claude with cwd=target_repo" {
  grep -q 'dr_pipeline.py" tracks\|DR_PY" tracks' "$SCRIPT" || grep -q '"\$DR_PY" tracks' "$SCRIPT"
  grep -q 'cd "\$TARGET_REPO"' "$SCRIPT"
}

@test "orchestrator injects past themes and line brief into per-line prompt" {
  grep -q '過去テーマ履歴' "$SCRIPT"
  grep -q 'PAST_THEMES' "$SCRIPT"
  grep -q 'line-brief' "$SCRIPT"
}

@test "orchestrator restricts file writes to vault, state, and past_topics (repo read-only)" {
  # path 規則は Edit(path) だけが consult される仕様 — Write(path) 規則は書かない
  grep -q 'Edit(//' "$SCRIPT"
  ! grep -q 'Write(' "$SCRIPT"
  grep -q 'past_topics.json)' "$SCRIPT"
  # 無条件の Write/Edit (path 制限なし) を allowedTools に入れていない
  ! grep -qE 'ALLOWED_TOOLS="[^"]*,(Write|Edit),' "$SCRIPT"
}

@test "orchestrator uses per-repo research protocol as system prompt" {
  grep -q 'append-system-prompt-file' "$SCRIPT"
  grep -q 'repo-research-protocol.md' "$SCRIPT"
}

@test "concept-graph selection machinery is retired (ADR-0008)" {
  ! grep -q 'coverage-report' "$SCRIPT"
  ! grep -q 'cluster-report' "$SCRIPT"
  ! grep -q 'sync_repo_graphs' "$SCRIPT"
  ! grep -q 'validate_theme_json' "$SCRIPT"
  [ ! -f "$PROJECT_DIR/scripts/coverage-report.sh" ]
  [ ! -f "$PROJECT_DIR/scripts/bootstrap-graph.sh" ]
  [ ! -f "$PROJECT_DIR/scripts/lib/graph.sh" ]
}

# === 新プロトコルの contract (repo-research-protocol.md) ===

@test "protocol leads with actionable objective, not corroboration" {
  grep -q '今すぐ前に進める、実行可能な手' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q '裏付け (corroboration) は成果ではない' "$PROJECT_DIR/prompts/repo-research-protocol.md"
}

@test "protocol mandates diff-first, premise-challenge, citation gate, self-signal guard" {
  grep -q 'diff パス' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q '前提挑戦パス' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q 'citation ゲート' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q '自己汚染ガード' "$PROJECT_DIR/prompts/repo-research-protocol.md"
}

@test "protocol declares repo read-only and forbids tactic quota" {
  grep -q 'repo は read-only' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q 'ノルマは存在しない' "$PROJECT_DIR/prompts/repo-research-protocol.md"
}

@test "template requires expiry conditions and contradiction section" {
  grep -q '失効条件' "$PROJECT_DIR/templates/report-template.md"
  grep -q '我々の立場と矛盾・複雑化する知見' "$PROJECT_DIR/templates/report-template.md"
  grep -q '今すぐ実行可能な手' "$PROJECT_DIR/templates/report-template.md"
}

# === Config files exist ===

@test "config.toml exists" {
  [ -f "$PROJECT_DIR/config.toml" ]
}

@test "repo-research-protocol.md exists (old prompts retired)" {
  [ -f "$PROJECT_DIR/prompts/repo-research-protocol.md" ]
  [ ! -f "$PROJECT_DIR/prompts/theme-selection-prompt.md" ]
  [ ! -f "$PROJECT_DIR/prompts/task-prompt.md" ]
  [ ! -f "$PROJECT_DIR/prompts/research-protocol.md" ]
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

@test "brief plist is valid and scheduled at 7:00" {
  plutil -lint "$PROJECT_DIR/com.shimomoto.daily-research-brief.plist"
  local hour
  hour=$(plutil -extract StartCalendarInterval.Hour raw \
    "$PROJECT_DIR/com.shimomoto.daily-research-brief.plist")
  [ "$hour" = "7" ]
  plutil -extract ProgramArguments json \
    "$PROJECT_DIR/com.shimomoto.daily-research-brief.plist" \
    -o - | grep -q "morning-brief.sh"
}

# === Morning brief (7:00 Slack 承認リクエスト) ===

@test "morning-brief extracts tactics deterministically (no LLM call)" {
  # 抽出は awk、送信は wiki_notify (呼び出し元シェル)。claude 呼び出しを含まない
  grep -q '今すぐ実行可能な手' "$BRIEF"
  grep -q 'wiki_notify' "$BRIEF"
  ! grep -q 'run_claude\|claude -p' "$BRIEF"
}

@test "morning-brief sends honest negative when no tactics" {
  grep -q '本日 actionable なし' "$BRIEF"
  grep -q 'ノートがありません\|ノートなし' "$BRIEF"
}

# === Lock mechanism ===

@test "orchestrator uses mkdir-atomic lock via lib/lock.sh" {
  grep -q 'source.*lock.sh' "$SCRIPT"
  grep -q 'acquire_lock' "$SCRIPT"
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
  grep -q "unset ANTHROPIC_API_KEY" "$PROJECT_DIR/scripts/lib/env.sh"
}

@test "no hardcoded API keys in script" {
  ! grep -qE '(sk-[a-zA-Z0-9]{20,}|api_key\s*=\s*"[^"]+")' "$SCRIPT"
}

@test "log file permissions are restricted (chmod 600)" {
  grep -q 'chmod 600 "$LOG_FILE"' "$PROJECT_DIR/scripts/lib/log.sh"
}

# === Defensive programming ===

@test "set -euo pipefail is configured" {
  head -3 "$SCRIPT" | grep -q "set -euo pipefail"
}

@test "trap release_lock is registered on EXIT" {
  grep -q 'trap release_lock EXIT' "$SCRIPT"
}

@test "max-turns is configured" {
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

@test "metrics.jsonl and state/ are gitignored (personal data, public repo)" {
  grep -qx 'metrics.jsonl' "$PROJECT_DIR/.gitignore"
  grep -qx 'state/' "$PROJECT_DIR/.gitignore"
}
