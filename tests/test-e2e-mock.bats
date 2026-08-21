#!/usr/bin/env bats
# E2E tests with mock claude command (per-repo in-context research, ADR-0008)
# Run: bats tests/test-e2e-mock.bats
#
# mock claude を $MOCK_HOME/.claude/local/ に配置し、
# daily-research.sh の PATH 優先ロジックで本物より先に見つかるようにする。
# HOME を差し替えることで本番環境に影響を与えない。

REAL_PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# === Setup / Teardown ===

setup() {
  MOCK_HOME="$(mktemp -d)"
  MOCK_PROJECT="$MOCK_HOME/MyAI_Lab/daily-research"

  # プロジェクト構造を再現
  mkdir -p "$MOCK_PROJECT/scripts"
  mkdir -p "$MOCK_PROJECT/prompts"
  mkdir -p "$MOCK_PROJECT/templates"
  mkdir -p "$MOCK_PROJECT/logs"

  # スクリプト・プロンプト・テンプレートをコピー
  cp "$REAL_PROJECT_DIR/scripts/daily-research.sh" "$MOCK_PROJECT/scripts/"
  cp -R "$REAL_PROJECT_DIR/scripts/lib" "$MOCK_PROJECT/scripts/"
  cp "$REAL_PROJECT_DIR/prompts/repo-research-protocol.md" "$MOCK_PROJECT/prompts/"
  cp "$REAL_PROJECT_DIR/prompts/clarity-review-protocol.md" "$MOCK_PROJECT/prompts/"
  cp "$REAL_PROJECT_DIR/templates/report-template.md" "$MOCK_PROJECT/templates/"

  # 対象 repo (cwd になる) を作る。akc / authorship の 2 line 構成
  mkdir -p "$MOCK_HOME/mock-repos/agent-knowledge-cycle"
  mkdir -p "$MOCK_HOME/mock-repos/authorship-strategy"

  cat > "$MOCK_PROJECT/config.toml" << EOF
[general]
vault_path = "$MOCK_HOME/mock-vault"
output_dir = "daily-research"
self_signals = ["github.com/example-author"]

[report]
min_sources = 5

[tracks.akc]
name = "AKC Line"
focus = "AKC line focus"

[[tracks.akc.repos]]
key = "akc"
target_repo = "$MOCK_HOME/mock-repos/agent-knowledge-cycle"

[tracks.authorship]
name = "Authorship Line"
focus = "Authorship line focus"

[[tracks.authorship.repos]]
key = "authorship"
target_repo = "$MOCK_HOME/mock-repos/authorship-strategy"
EOF

  # past_topics.json のミニマル版
  cat > "$MOCK_PROJECT/past_topics.json" << 'EOF'
{
  "topics": []
}
EOF

  # rotation (ADR-0010): DR_DATE seam で日付を固定し、pick を決定論にする。
  # 2026-08-13 の ordinal は奇数 → 2 行 config (akc, authorship) では index 1 =
  # authorship が選ばれる (rotation-pick の周期性は pytest 側が検証済み)。
  export DR_DATE="2026-08-13"
  PICKED="authorship"
  OTHER="akc"

  # mock claude を配置（スクリプトが $HOME/.claude/local を PATH に追加する）
  mkdir -p "$MOCK_HOME/.claude/local"

  # mock の挙動は MOCK_SCENARIO ファイルで制御
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  create_mock_claude
}

teardown() {
  rm -rf "$MOCK_HOME"
}

# === Mock claude generator ===

create_mock_claude() {
  cat > "$MOCK_HOME/.claude/local/claude" << 'MOCK_SCRIPT'
#!/bin/bash
# Mock claude for E2E testing (per-repo single-pass, ADR-0008)
MOCK_HOME_DIR="$(dirname "$(dirname "$(dirname "$0")")")"
SCENARIO=$(cat "$MOCK_HOME_DIR/.mock_scenario" 2>/dev/null || echo "normal")

# --version check
if [[ "$1" == "--version" ]]; then
  echo "2.1.47 (Claude Code - Mock)"
  exit 0
fi

# Parse flags (-p prompt / --append-system-prompt-file / --allowedTools)
# 呼び分けは protocol ファイルで判定する — model は budget 都合で変わりうる
# tunable であり、役割の識別子は protocol の方 (ADR-0010)。
PROTOCOL=""
PROMPT=""
ALLOWED=""
DISALLOWED=""
PREV=""
for arg in "$@"; do
  case "$PREV" in
    --append-system-prompt-file) PROTOCOL="$arg" ;;
    -p) PROMPT="$arg" ;;
    --allowedTools) ALLOWED="$arg" ;;
    --disallowedTools) DISALLOWED="$arg" ;;
  esac
  PREV="$arg"
done

# --- Auth probe (protocol ファイルなしの軽量呼び出し) ---
if [[ -z "$PROTOCOL" ]]; then
  case "$SCENARIO" in
    auth-fail|auth-401)
      echo '{"type":"result","subtype":"error","is_error":true,"api_error_status":401,"total_cost_usd":0,"result":"Failed to authenticate. API Error: 401 Invalid authentication credentials"}'
      exit 1
      ;;
    *)
      echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.001,"num_turns":1,"duration_ms":2000,"usage":{"input_tokens":100,"output_tokens":10}}'
      exit 0
      ;;
  esac
fi

# --- 呼1: per-line research run (repo-research-protocol.md) ---
if [[ "$PROTOCOL" == *repo-research-protocol.md ]]; then
  # プロンプトから track を抽出 (per-line プロンプトの "- line (track): X" 行)
  TRACK=$(printf '%s\n' "$PROMPT" | sed -n 's/^- line (track): //p' | head -1)
  TRACK=${TRACK:-unknown}

  # 検証用にプロンプトと allowedTools を track 別に記録
  printf '%s' "$PROMPT" > "$MOCK_HOME_DIR/.prompt_$TRACK"
  printf '%s' "$ALLOWED" > "$MOCK_HOME_DIR/.allowed_$TRACK"
  printf '%s' "$DISALLOWED" > "$MOCK_HOME_DIR/.disallowed_$TRACK"
  # 呼び出し回数カウンタ (retry テスト用)
  COUNT_FILE="$MOCK_HOME_DIR/.calls_$TRACK"
  COUNT=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$COUNT" > "$COUNT_FILE"

  # track 別失敗 seam: $MOCK_HOME/.fail_tracks に track 名を 1 行 1 つ書くと
  # その track の run だけが恒常失敗する (部分失敗テスト用)
  if [[ -f "$MOCK_HOME_DIR/.fail_tracks" ]] && grep -qx "$TRACK" "$MOCK_HOME_DIR/.fail_tracks"; then
    echo "ERROR: simulated failure for track $TRACK" >&2
    exit 1
  fi

  case "$SCENARIO" in
    run-401)
      echo '{"type":"result","subtype":"error","is_error":true,"api_error_status":401,"duration_ms":2700,"result":"Failed to authenticate. API Error: 401"}'
      exit 1
      ;;
    run-fail-once)
      # 1 回目は失敗、リトライ (2 回目) で成功
      if [[ "$COUNT" -eq 1 ]]; then
        echo "ERROR: simulated transient failure" >&2
        exit 1
      fi
      ;;
    run-fail-always)
      # 担当 line が恒常失敗 (リトライも失敗) → E_NO_REPORT
      echo "ERROR: simulated line failure" >&2
      exit 1
      ;;
    run-iserror)
      echo '[{"type":"assistant","message":{"content":[]}},{"type":"result","subtype":"error","is_error":true,"total_cost_usd":0.05,"num_turns":55,"duration_ms":30000,"usage":{"input_tokens":2000,"output_tokens":800}}]'
      exit 0
      ;;
  esac

  # noreport: success を返すがレポートを書かない (成功化け → ctl-015 が捕捉すべき)
  REPORT_DIR="$MOCK_HOME_DIR/mock-vault/daily-research"
  mkdir -p "$REPORT_DIR"
  case "$SCENARIO" in
    noreport) ;;
    comma-name)
      # model が allowedTools 注入を狙うファイル名 (カンマ入り slug) を書く
      echo "# mock report for $TRACK" > "$REPORT_DIR/${DR_DATE}_${TRACK}_x),Write,Read(a.md"
      ;;
    two-reports)
      # 同 line に 2 ノート — 呼2 は最新 mtime の方を対象にすべき
      echo "# older" > "$REPORT_DIR/${DR_DATE}_${TRACK}_older.md"
      sleep 1
      echo "# newest" > "$REPORT_DIR/${DR_DATE}_${TRACK}_newest.md"
      ;;
    *)
      echo "# mock report for $TRACK" > "$REPORT_DIR/${DR_DATE:-$(date +%Y-%m-%d)}_${TRACK}_mock-report.md"
      ;;
  esac

  echo '[{"type":"assistant","message":{"content":[]}},{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.05,"num_turns":3,"duration_ms":30000,"usage":{"input_tokens":2000,"output_tokens":800}}]'
  exit 0
fi

# --- 呼2: clarity 改稿 (clarity-review-protocol.md、ADR-0010) ---
if [[ "$PROTOCOL" == *clarity-review-protocol.md ]]; then
  printf '%s' "$PROMPT" > "$MOCK_HOME_DIR/.prompt_clarity"
  printf '%s' "$ALLOWED" > "$MOCK_HOME_DIR/.allowed_clarity"
  printf '%s' "$DISALLOWED" > "$MOCK_HOME_DIR/.disallowed_clarity"

  if [[ "$SCENARIO" == "clarity-fail" ]]; then
    echo "ERROR: simulated clarity failure" >&2
    exit 1
  fi

  echo '[{"type":"assistant","message":{"content":[]}},{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.02,"num_turns":2,"duration_ms":8000,"usage":{"input_tokens":1500,"output_tokens":300}}]'
  exit 0
fi

echo "Unknown protocol: $PROTOCOL" >&2
exit 1
MOCK_SCRIPT
  chmod +x "$MOCK_HOME/.claude/local/claude"
}

# === Helper ===

run_script() {
  HOME="$MOCK_HOME" DEBUG=1 bash "$MOCK_PROJECT/scripts/daily-research.sh" 2>&1
}

# daily = true の line を config に追記する (輪番の周期・位相は変えない)
add_daily_line() {
  mkdir -p "$MOCK_HOME/mock-repos/desire-frontier"
  cat >> "$MOCK_PROJECT/config.toml" << EOF

[tracks.desire]
name = "Desire Line"
focus = "Desire line focus"
daily = true

[[tracks.desire.repos]]
key = "desire"
target_repo = "$MOCK_HOME/mock-repos/desire-frontier"
EOF
}

# 輪番外 (daily でない) の line を config に追記する。fixture の輪番 4 line の末尾に
# 足すので位相が変わりうる — DR_FORCE_TRACK のように輪番を使わない test 専用
add_rotating_line() {
  mkdir -p "$MOCK_HOME/mock-repos/desire-frontier"
  cat >> "$MOCK_PROJECT/config.toml" << EOF

[tracks.desire]
name = "Desire Line"
focus = "Desire line focus"

[[tracks.desire.repos]]
key = "desire"
target_repo = "$MOCK_HOME/mock-repos/desire-frontier"
EOF
}

get_log() {
  cat "$MOCK_PROJECT/logs/$DR_DATE.log"
}

# === Test: Normal path (rotation: 当日担当 1 line のみ、ADR-0010) ===

@test "E2E normal: only the rotation-picked line runs and its report passes the gate" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run_script
  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "Rotation pick: $PICKED"
  echo "$log_content" | grep -q "Line: $PICKED"
  ! echo "$log_content" | grep -q "Line: $OTHER"
  echo "$log_content" | grep -q "Line $PICKED report gate passed"
  echo "$log_content" | grep -q "Report existence gate passed: 1 report(s)"
  echo "$log_content" | grep -q "Completed successfully"
  echo "$log_content" | grep -q "DEBUG: CLAUDE_CMD="
  # 担当外 line の run は発生しない
  [ ! -f "$MOCK_HOME/.prompt_$OTHER" ]
}

@test "E2E daily: a daily line runs every day in addition to the rotation pick" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  add_daily_line

  run_script
  local log_content
  log_content=$(get_log)

  # 輪番の pick は daily 追加前と同じ (daily は輪番の外)
  echo "$log_content" | grep -q "Rotation pick: $PICKED"
  echo "$log_content" | grep -q "Line: $PICKED"
  echo "$log_content" | grep -q "Line: desire"
  ! echo "$log_content" | grep -q "Line: $OTHER"
  # 両 line がゲートを通り、レポートは 2 本
  echo "$log_content" | grep -q "Line $PICKED report gate passed"
  echo "$log_content" | grep -q "Line desire report gate passed"
  echo "$log_content" | grep -q "Report existence gate passed: 2 report(s)"
  echo "$log_content" | grep -q "SUMMARY Run($PICKED):"
  echo "$log_content" | grep -q "SUMMARY Run(desire):"
  echo "$log_content" | grep -q "Completed successfully"
  # 呼2 clarity は line ごとに走る
  [ "$(echo "$log_content" | grep -c 'Clarity pass ok')" -eq 2 ]
  [ -f "$MOCK_HOME/mock-vault/daily-research/${DR_DATE}_${PICKED}_mock-report.md" ]
  [ -f "$MOCK_HOME/mock-vault/daily-research/${DR_DATE}_desire_mock-report.md" ]
}

@test "E2E daily: partial failure — daily line fails but rotation line's results survive" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  printf 'desire\n' > "$MOCK_HOME/.fail_tracks"
  add_daily_line

  run run_script
  [ "$status" -ne 0 ]

  local log_content
  log_content=$(get_log)

  # 先行 line (輪番) は完走し、成果は集計に残る
  echo "$log_content" | grep -q "Line $PICKED report gate passed"
  echo "$log_content" | grep -q "report gate failed for line desire"
  echo "$log_content" | grep -q "Failed (E_PARTIAL"
  ! echo "$log_content" | grep -q "Completed successfully"
  echo "$log_content" | grep -q "metrics: appended"
  [ -f "$MOCK_HOME/mock-vault/daily-research/${DR_DATE}_${PICKED}_mock-report.md" ]
  [ ! -f "$MOCK_HOME/mock-vault/daily-research/${DR_DATE}_desire_mock-report.md" ]
  # clarity は成功 line の分だけ走る
  [ "$(echo "$log_content" | grep -c 'Clarity pass ok')" -eq 1 ]
}

@test "E2E daily: 401 mid-loop aborts remaining lines but keeps prior results" {
  echo "run-401" > "$MOCK_HOME/.mock_scenario"
  add_daily_line

  run run_script
  [ "$status" -ne 0 ]

  local log_content
  log_content=$(get_log)

  # 1 line 目 (輪番) が 401 → 残 line (desire) は実行されない
  echo "$log_content" | grep -q "returned 401 — aborting remaining lines"
  echo "$log_content" | grep -q "skipping remaining lines"
  [ ! -f "$MOCK_HOME/.prompt_desire" ]
  # 即 exit しない — 集計 (metrics) は走る
  echo "$log_content" | grep -q "metrics: appended"
  echo "$log_content" | grep -q "Failed (E_NO_REPORT"
}

@test "E2E normal: per-line prompt carries line brief, paths, and past themes" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run_script

  local prompt
  prompt=$(cat "$MOCK_HOME/.prompt_$PICKED")
  echo "$prompt" | grep -q -- "- line (track): $PICKED"
  echo "$prompt" | grep -q "line focus"
  echo "$prompt" | grep -q "過去テーマ履歴"
  echo "$prompt" | grep -q "state/$PICKED"
  echo "$prompt" | grep -q "past_topics.json"
  echo "$prompt" | grep -q "機会メモ"   # テンプレート注入
  echo "$prompt" | grep -q "この repo への含意"  # 4 節骨格 (ADR-0014) のテンプレート注入
  ! echo "$prompt" | grep -q "判断基準 (優先順)"  # scoring_criteria は廃止 (ADR-0014)
  echo "$prompt" | grep -q "github.com/example-author"  # self_signals
}

@test "E2E normal: file writes are path-restricted (repo read-only at permission layer)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run_script

  local allowed
  allowed=$(cat "$MOCK_HOME/.allowed_$PICKED")
  # path 規則は Edit(path) だけが consult される仕様 — Write(path) 規則は書かない
  echo "$allowed" | grep -q "Edit(//"
  echo "$allowed" | grep -q "mock-vault/daily-research"
  echo "$allowed" | grep -q "state/$PICKED"
  echo "$allowed" | grep -q "past_topics.json)"
  ! echo "$allowed" | grep -q "Write("
  # 無条件 Write/Edit は含まれない
  ! printf '%s' "$allowed" | grep -qE '(^|,)Write(,|$)'
  ! printf '%s' "$allowed" | grep -qE '(^|,)Edit(,|$)'
}

@test "E2E normal: state directory is created for the picked line only" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run_script
  [ -d "$MOCK_PROJECT/state/$PICKED" ]
  [ ! -d "$MOCK_PROJECT/state/$OTHER" ]
}

# === Test: Clarity 呼2 (ADR-0010) ===

@test "E2E clarity: second pass reviews the picked report with restricted tools" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run_script
  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "Clarity pass:"
  echo "$log_content" | grep -q "SUMMARY Clarity:"
  echo "$log_content" | grep -q "Clarity pass ok"

  # 呼2 は対象ノートだけを Edit でき、リサーチツール・Bash・glob 権限を持たない
  local allowed prompt
  allowed=$(cat "$MOCK_HOME/.allowed_clarity")
  echo "$allowed" | grep -q "Edit(//"
  echo "$allowed" | grep -q "mock-vault/daily-research/${DR_DATE}_${PICKED}_"
  ! echo "$allowed" | grep -q "WebSearch"
  ! echo "$allowed" | grep -q "WebFetch"
  ! echo "$allowed" | grep -q "Bash"
  ! echo "$allowed" | grep -q '\*\*'          # 単一ファイル限定 — glob を含まない
  ! echo "$allowed" | grep -q "past_topics"
  ! echo "$allowed" | grep -q "state/"
  prompt=$(cat "$MOCK_HOME/.prompt_clarity")
  echo "$prompt" | grep -q "対象ファイル"
}

@test "E2E clarity: clarity failure is fail-open (report survives, run still succeeds)" {
  echo "clarity-fail" > "$MOCK_HOME/.mock_scenario"

  run_script
  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "WARN: clarity pass failed"
  echo "$log_content" | grep -q "Completed successfully"
  ls "$MOCK_HOME/mock-vault/daily-research/${DR_DATE}_${PICKED}_"*.md
}

# === Test: Retry (per-line, once) ===

@test "E2E retry: transient failure retries once then succeeds" {
  echo "run-fail-once" > "$MOCK_HOME/.mock_scenario"

  run_script
  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "retrying once"
  echo "$log_content" | grep -q "Completed successfully"
}

@test "E2E fail: picked line failing after retry yields overall Failed (E_NO_REPORT)" {
  echo "run-fail-always" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -ne 0 ]

  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "failed after retry"
  echo "$log_content" | grep -q "report gate failed for line $PICKED"
  ! echo "$log_content" | grep -q "Completed successfully"
  echo "$log_content" | grep -q "Failed (E_NO_REPORT"
  # レポートが無いので clarity 呼2 は走らない
  [ ! -f "$MOCK_HOME/.prompt_clarity" ]
}

# === Test: Auth probe / 401 ===

@test "E2E auth: failed auth probe stops before any line run" {
  echo "auth-fail" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -ne 0 ]

  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "Auth probe failed"
  ! echo "$log_content" | grep -q "Line: $PICKED"
  [ ! -f "$MOCK_HOME/.prompt_$PICKED" ]
}

@test "E2E auth: 401 during the line run aborts immediately (no retry, no clarity)" {
  echo "run-401" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -ne 0 ]

  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "returned 401 — aborting"
  ! echo "$log_content" | grep -q "retrying once"
  [ ! -f "$MOCK_HOME/.prompt_clarity" ]
}

# === Test: 成功化け防止 (is_error / ctl-015) ===

@test "E2E: exit 0 with is_error is reported as Failed (no success masking)" {
  echo "run-iserror" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -ne 0 ]

  local log_content
  log_content=$(get_log)

  ! echo "$log_content" | grep -q "Completed successfully"
  echo "$log_content" | grep -q "Failed (E_NO_REPORT"
}

@test "E2E: success without report files is reported as Failed (report existence gate)" {
  echo "noreport" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -ne 0 ]

  local log_content
  log_content=$(get_log)

  ! echo "$log_content" | grep -q "Completed successfully"
  echo "$log_content" | grep -q "ctl-015"
  echo "$log_content" | grep -q "Failed (E_NO_REPORT"
}

# === Test: deny 層 — defaultMode=auto 下でも Bash が model に渡らない (2026-08-22 security review) ===
@test "E2E security: both calls pass --disallowedTools with Bash (allow list is not a restriction under auto mode)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run_script

  grep -qE '(^|,)Bash(,|$)' "$MOCK_HOME/.disallowed_$PICKED"
  grep -qE '(^|,)Bash(,|$)' "$MOCK_HOME/.disallowed_clarity"
}

# === Test: ctl-015 は run スコープ — 同日の先行ノートでは gate が通らない ===
@test "E2E gate: a pre-existing same-day report does not satisfy the gate for a run that wrote nothing" {
  echo "noreport" > "$MOCK_HOME/.mock_scenario"
  mkdir -p "$MOCK_HOME/mock-vault/daily-research"
  echo "# stale" > "$MOCK_HOME/mock-vault/daily-research/${DR_DATE}_${PICKED}_stale.md"
  touch -t 202001010000 "$MOCK_HOME/mock-vault/daily-research/${DR_DATE}_${PICKED}_stale.md"

  run run_script
  [ "$status" -ne 0 ]
  get_log | grep -q "ctl-015"
  ! get_log | grep -q "Clarity pass:"
}

# === Test: 複数ノート時は最新 mtime が呼2 の対象 (find の readdir 順に依存しない) ===
@test "E2E clarity: with two reports for one line, the newest one is reviewed" {
  echo "two-reports" > "$MOCK_HOME/.mock_scenario"

  run_script

  get_log | grep -q "Clarity pass: ${DR_DATE}_${PICKED}_newest.md"
  grep -q "_newest.md)" "$MOCK_HOME/.allowed_clarity"
}

# === Test: カンマ入りファイル名は呼2 の allowedTools へ注入されない ===
@test "E2E security: a report filename with a comma is rejected, never embedded in clarity --allowedTools" {
  echo "comma-name" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -ne 0 ]
  get_log | grep -q "report filename rejected"
  get_log | grep -q "ctl-015"
  [ ! -f "$MOCK_HOME/.allowed_clarity" ]
}

# === Test: 不在 repo は skip され部分失敗になる ===

@test "E2E: missing target_repo is skipped with WARN and counted as failed line" {
  # rotation で必ず ghost が選ばれるよう、ghost 1 line だけの config に置き換える
  cat > "$MOCK_PROJECT/config.toml" << EOF
[general]
vault_path = "$MOCK_HOME/mock-vault"
output_dir = "daily-research"

[tracks.ghost]
name = "Ghost Line"

[[tracks.ghost.repos]]
key = "ghost"
target_repo = "$MOCK_HOME/mock-repos/does-not-exist"
EOF

  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -ne 0 ]

  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "target_repo が存在しない"
  echo "$log_content" | grep -q "report gate failed for line ghost"
}

# === Test: Legacy config schema fail-fast (ADR-0004) ===

@test "E2E: legacy config schema stops before any line run (fail-fast)" {
  cat > "$MOCK_PROJECT/config.toml" << 'EOF'
[general]
vault_path = "/tmp/mock-vault"

[tracks.authorship]
name = "Legacy Track"
target_repo = "/tmp/mock-repos/authorship-strategy"
EOF

  run run_script
  [ "$status" -ne 0 ]

  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "config.toml schema check failed"
  [ ! -f "$MOCK_HOME/.prompt_authorship" ]
}

# === Test: Absolute path resolution ===

@test "E2E: CLAUDE_CMD resolves to absolute path in .claude/local" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run_script
  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "DEBUG: CLAUDE_CMD=$MOCK_HOME/.claude/local/claude"
}

# === Test: No legacy gtimeout dependency ===

@test "E2E: script does not use gtimeout or legacy timeout patterns" {
  ! grep -v '^#\|^[[:space:]]*#' "$MOCK_PROJECT/scripts/daily-research.sh" | grep -q 'gtimeout\|TIMEOUT_CMD\|timeout_secs'
}

# === Test: 自己改善ループの計測 (ADR-0006 / ctl-016) ===

@test "E2E: metrics.jsonl records the picked run, clarity pass, and lint result" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run_script
  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "Completed successfully"
  # SUMMARY 行 (backfill regex の対象): 呼1 = Run(<track>)、呼2 = Clarity
  echo "$log_content" | grep -q "SUMMARY Run($PICKED):"
  echo "$log_content" | grep -q "SUMMARY Clarity:"
  ! echo "$log_content" | grep -q "SUMMARY Run($OTHER):"

  [ -f "$MOCK_PROJECT/metrics.jsonl" ]
  run python3 - "$MOCK_PROJECT/metrics.jsonl" << 'PYEOF'
import json, sys
rec = json.loads(open(sys.argv[1]).read().splitlines()[0])
assert rec["final_class"] == "OK", rec
assert rec["report_count"] == 1, rec
assert rec["source"] == "live", rec
assert rec["pass1"] is None, rec
assert rec["pass2"]["turns"] == 3, rec  # 呼1 単独 (rotation で 1 line)
assert rec["fallback_used"] is False, rec
# 呼2 clarity の発動記録 (ADR-0010) — verdict は保存しない
assert rec["clarity_pass"]["ran"] is True, rec
assert rec["clarity_pass"]["ok"] is True, rec
assert rec["clarity_pass"]["turns"] == 2, rec
# total_cost は呼1 + 呼2 の合算
assert abs(rec["total_cost"] - 0.07) < 1e-9, rec
# mock レポートはソース節なし → lint hard fail が記録される
assert rec["lint"]["hard_fail"] == 1, rec
PYEOF
  [ "$status" -eq 0 ]

  # ctl-016 hard fail が WARN されるが、FINAL_EXIT には影響しない (advisory)
  echo "$log_content" | grep -q "report lint hard fail (ctl-016)"

  # review リマインダー: state 不在 → never をログ
  echo "$log_content" | grep -q "dr-review age: never"
}

@test "E2E: clarity failure is recorded in metrics as ok=false" {
  echo "clarity-fail" > "$MOCK_HOME/.mock_scenario"

  run_script

  [ -f "$MOCK_PROJECT/metrics.jsonl" ]
  run python3 - "$MOCK_PROJECT/metrics.jsonl" << 'PYEOF'
import json, sys
rec = json.loads(open(sys.argv[1]).read().splitlines()[0])
assert rec["final_class"] == "OK", rec  # fail-open — run 全体は成功のまま
assert rec["clarity_pass"]["ran"] is True, rec
assert rec["clarity_pass"]["ok"] is False, rec
PYEOF
  [ "$status" -eq 0 ]
}

# === Test: DR_ONLY_TRACK seam (当日担当のうち 1 line だけ実行するテスト seam) ===

@test "E2E only-track: DR_ONLY_TRACK runs only the named line among today's lines" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  add_daily_line

  HOME="$MOCK_HOME" DR_ONLY_TRACK=desire bash "$MOCK_PROJECT/scripts/daily-research.sh" 2>&1
  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "DR_ONLY_TRACK seam: line desire のみ実行"
  echo "$log_content" | grep -q "Line: desire"
  ! echo "$log_content" | grep -q "Line: $PICKED"
  ! echo "$log_content" | grep -q "Rotation pick:"
  echo "$log_content" | grep -q "Line desire report gate passed"
  echo "$log_content" | grep -q "Completed successfully"
  # 輪番担当 line の run は発生しない
  [ ! -f "$MOCK_HOME/.prompt_$PICKED" ]
}

@test "E2E only-track: DR_ONLY_TRACK not in today's lines fails fast without running anything" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run env HOME="$MOCK_HOME" DR_ONLY_TRACK=nonexistent bash "$MOCK_PROJECT/scripts/daily-research.sh"
  [ "$status" -ne 0 ]
  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "DR_ONLY_TRACK=nonexistent は当日の担当 line に含まれない"
  ! echo "$log_content" | grep -q "=== Line:"
  [ ! -f "$MOCK_HOME/.prompt_$PICKED" ]
}

# === Test: DR_FORCE_TRACK seam (輪番外の line を今日の日付で実行するテスト seam) ===

@test "E2E force-track: DR_FORCE_TRACK runs a line that is not in today's rotation" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  add_rotating_line

  HOME="$MOCK_HOME" DR_FORCE_TRACK=desire bash "$MOCK_PROJECT/scripts/daily-research.sh" 2>&1
  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "DR_FORCE_TRACK seam: line desire を輪番外で実行"
  echo "$log_content" | grep -q "Line: desire"
  ! echo "$log_content" | grep -q "Rotation pick:"
  echo "$log_content" | grep -q "Line desire report gate passed"
  echo "$log_content" | grep -q "Completed successfully"
  # 輪番なら当日担当だったはずの line は走らない
  ! echo "$log_content" | grep -q "=== Line: akc"
  ! echo "$log_content" | grep -q "=== Line: authorship"
}

@test "E2E force-track: DR_FORCE_TRACK not in config fails fast" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run env HOME="$MOCK_HOME" DR_FORCE_TRACK=nonexistent bash "$MOCK_PROJECT/scripts/daily-research.sh"
  [ "$status" -ne 0 ]
  get_log | grep -q "DR_FORCE_TRACK=nonexistent は config.toml に無い"
  [ ! -f "$MOCK_HOME/.prompt_$PICKED" ]
}
