#!/usr/bin/env bats
# E2E tests with mock claude command (per-repo in-context research, ADR-0008)
# Run: bats tests/test-e2e-mock.bats
#
# mock claude を $MOCK_HOME/.claude/local/ に配置し、
# daily-research.sh の PATH 優先ロジックで本物より先に見つかるようにする。
# HOME を差し替えることで本番環境に影響を与えない。

REAL_PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

load test_helper

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
  cp "$REAL_PROJECT_DIR/prompts/ecosystem-research-protocol.md" "$MOCK_PROJECT/prompts/"
  # 呼2 protocol は mock が名前で識別するだけなので stub で足りる (ADR-0017)
  cp "$REAL_PROJECT_DIR/tests/fixtures/verification-protocol.stub.md" "$MOCK_PROJECT/prompts/verification-protocol.md"
  cp "$REAL_PROJECT_DIR/templates/report-template.md" "$MOCK_PROJECT/templates/"
  cp "$REAL_PROJECT_DIR/templates/report-template-ecosystem.md" "$MOCK_PROJECT/templates/"

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

# --- 呼1: per-line research run (repo-research-protocol.md、ecosystem line は
#     ecosystem-research-protocol.md — ADR-0018) ---
if [[ "$PROTOCOL" == *repo-research-protocol.md || "$PROTOCOL" == *ecosystem-research-protocol.md ]]; then
  # プロンプトから track を抽出 (per-line プロンプトの "- line (track): X" 行)
  TRACK=$(printf '%s\n' "$PROMPT" | sed -n 's/^- line (track): //p' | head -1)
  TRACK=${TRACK:-unknown}

  # 検証用にプロンプトと allowedTools を track 別に記録
  printf '%s' "$PROMPT" > "$MOCK_HOME_DIR/.prompt_$TRACK"
  printf '%s' "$ALLOWED" > "$MOCK_HOME_DIR/.allowed_$TRACK"
  printf '%s' "$DISALLOWED" > "$MOCK_HOME_DIR/.disallowed_$TRACK"
  # 実行形の検証用 (ADR-0018): cwd / protocol / 全引数を track 別に記録
  pwd -P > "$MOCK_HOME_DIR/.cwd_$TRACK"
  printf '%s' "$PROTOCOL" > "$MOCK_HOME_DIR/.protocol_$TRACK"
  printf '%s\n' "$@" > "$MOCK_HOME_DIR/.args_$TRACK"
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
    run-iserror-once)
      # attempt 1 は is_error (コスト $0.05 を消費して失敗)、attempt 2 で成功 →
      # metrics の pass2 は両 attempt の合算であるべき
      COUNT_FILE="$MOCK_HOME_DIR/.count_iserror_$TRACK"
      COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
      COUNT=$((COUNT + 1)); echo "$COUNT" > "$COUNT_FILE"
      if [[ "$COUNT" -eq 1 ]]; then
        echo '[{"type":"assistant","message":{"content":[]}},{"type":"result","subtype":"error","is_error":true,"total_cost_usd":0.05,"num_turns":55,"duration_ms":30000,"usage":{"input_tokens":2000,"output_tokens":800}}]'
        exit 0
      fi
      ;;
  esac

  # 内容状態 seam (ADR-0017): $MOCK_HOME/.state_<track> に article|brief|quiet|hold
  # (既定 article)、.reason_code_<track> に reason_code (既定 no_new_evidence)。
  STATE=$(cat "$MOCK_HOME_DIR/.state_$TRACK" 2>/dev/null || echo article)
  REASON_CODE=$(cat "$MOCK_HOME_DIR/.reason_code_$TRACK" 2>/dev/null || echo no_new_evidence)
  RECEIPT=$(printf '%s\n' "$PROMPT" | grep -oE '/[^ ]*/runs/[0-9-]+\.json' | head -1)
  EVIDENCE=$(printf '%s\n' "$PROMPT" | grep -oE '/[^ ]*/runs/[0-9-]+\.md' | head -1)
  printf '%s' "$RECEIPT" > "$MOCK_HOME_DIR/.receipt_path_$TRACK"

  REPORT_DIR="$MOCK_HOME_DIR/mock-vault/daily-research"
  mkdir -p "$REPORT_DIR"
  REPORT_NAME="${DR_DATE:-$(date +%Y-%m-%d)}_${TRACK}_mock-report.md"
  write_receipt() {  # $1 = status, $2 = report basename or empty
    local report_json=null
    [ -n "$2" ] && report_json="\"$2\""
    printf '{"date": "%s", "line": "%s", "status": "%s", "report": %s, "question": "mock question for %s", "reason": "mock reason", "reason_code": "%s", "answer_scope": "mock scope", "title": "mock title for %s"}\n' \
      "$DR_DATE" "$TRACK" "$1" "$report_json" "$TRACK" "$REASON_CODE" "$TRACK" > "$RECEIPT"
  }

  case "$SCENARIO" in
    noreport) ;;   # success を返すが何も書かない (成功化け → receipt gate が捕捉すべき)
    receipt-missing)
      echo "# mock report for $TRACK" > "$REPORT_DIR/$REPORT_NAME"
      ;;
    receipt-article-no-file)
      write_receipt article "$REPORT_NAME"
      ;;
    receipt-quiet-with-file)
      echo "# mock report for $TRACK" > "$REPORT_DIR/$REPORT_NAME"
      write_receipt quiet ""
      ;;
    receipt-bad-json)
      echo "# mock report for $TRACK" > "$REPORT_DIR/$REPORT_NAME"
      echo "not json" > "$RECEIPT"
      ;;
    comma-name)
      # model が allowedTools 注入を狙うファイル名 (カンマ入り slug) を書く
      _bad="${DR_DATE}_${TRACK}_x),Write,Read(a.md"
      echo "# mock report for $TRACK" > "$REPORT_DIR/$_bad"
      write_receipt article "$_bad"
      ;;
    two-reports)
      # 同 line に 2 ノート — 呼2 は最新 mtime の方を対象にすべき
      echo "# older" > "$REPORT_DIR/${DR_DATE}_${TRACK}_older.md"
      sleep 1
      echo "# newest" > "$REPORT_DIR/${DR_DATE}_${TRACK}_newest.md"
      write_receipt article "${DR_DATE}_${TRACK}_newest.md"
      ;;
    *)
      case "$STATE" in
        article|brief)
          if [ "$STATE" = "brief" ]; then
            printf -- '---\nkind: brief\n---\n\n# mock brief for %s\n' "$TRACK" > "$REPORT_DIR/$REPORT_NAME"
          else
            echo "# mock report for $TRACK" > "$REPORT_DIR/$REPORT_NAME"
          fi
          echo "# evidence for $TRACK" > "$EVIDENCE"
          write_receipt "$STATE" "$REPORT_NAME"
          ;;
        quiet|hold)
          write_receipt "$STATE" ""
          ;;
      esac
      ;;
  esac

  # 検索回数: 実出力と同じく modelUsage.<model>.webSearchRequests に載せる。
  # .nosearch_<track> があれば検索 0 回の run を返す (quiet-suspect テスト用)
  SEARCH_USAGE=',"modelUsage":{"mock-haiku":{"webSearchRequests":4}}'
  [ -f "$MOCK_HOME_DIR/.nosearch_$TRACK" ] && SEARCH_USAGE=''
  echo '[{"type":"assistant","message":{"content":[]}},{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.05,"num_turns":3,"duration_ms":30000,"usage":{"input_tokens":2000,"output_tokens":800}'"$SEARCH_USAGE"'}]'
  exit 0
fi

# --- 呼2: clarity 改稿 + 原典照合 (verification-protocol.md、ADR-0010/0017) ---
if [[ "$PROTOCOL" == *verification-protocol.md ]]; then
  printf '%s' "$PROMPT" > "$MOCK_HOME_DIR/.prompt_clarity"
  printf '%s' "$ALLOWED" > "$MOCK_HOME_DIR/.allowed_clarity"
  printf '%s' "$DISALLOWED" > "$MOCK_HOME_DIR/.disallowed_clarity"
  printf '%s\n' "$@" > "$MOCK_HOME_DIR/.args_clarity"

  if [[ "$SCENARIO" == "clarity-fail" ]]; then
    echo "ERROR: simulated clarity failure" >&2
    exit 1
  fi

  # verify.json はプロンプトに渡されたパスへ書く (verify-missing は書かない)
  if [[ "$SCENARIO" != "verify-missing" ]]; then
    VERIFY=$(printf '%s\n' "$PROMPT" | grep -oE '/[^ ]*/runs/[0-9-]+\.verify\.json' | head -1)
    [ -n "$VERIFY" ] && printf '{"supported": 3, "partial": 1, "unsupported": 0, "unverifiable": 1, "edits": 2}\n' > "$VERIFY"
  fi

  echo '[{"type":"assistant","message":{"content":[]}},{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.02,"num_turns":2,"duration_ms":8000,"usage":{"input_tokens":1500,"output_tokens":300}}]'
  exit 0
fi

echo "Unknown protocol: $PROTOCOL" >&2
exit 1
MOCK_SCRIPT
  chmod +x "$MOCK_HOME/.claude/local/claude"

  # osascript stub: 通知本文を $MOCK_HOME/.notify_log に記録する (本物の通知を出さない)。
  # lib/env.sh が $HOME/.claude/local を PATH 先頭に置くので /usr/bin より先に見つかる。
  cat > "$MOCK_HOME/.claude/local/osascript" << 'STUB'
#!/bin/bash
MOCK_HOME_DIR="$(dirname "$(dirname "$(dirname "$0")")")"
printf '%s\n' "$*" >> "$MOCK_HOME_DIR/.notify_log"
exit 0
STUB
  chmod +x "$MOCK_HOME/.claude/local/osascript"
}

# 記録された通知本文に固定文字列が含まれるか
notified() {
  grep -qF -- "$1" "$MOCK_HOME/.notify_log"
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

# mode = "ecosystem" の daily line を config に追記する (ADR-0018)。接地 repo を持たない —
# mock-repos 配下に dir を作らないこと自体が「repo 文脈を要求しない」の検証になる
add_ecosystem_daily_line() {
  cat >> "$MOCK_PROJECT/config.toml" << EOF

[tracks.eco]
name = "Ecosystem Line"
mode = "ecosystem"
daily = true
template = "templates/report-template-ecosystem.md"
focus = "Ecosystem line focus"
sources = ["fixture-eco-source"]
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
  refute_grep -q "Line: $OTHER" <<< "$log_content"
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
  refute_grep -q "Line: $OTHER" <<< "$log_content"
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
  refute_grep -q "Completed successfully" <<< "$log_content"
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
  # past_topics はモデルに書かせない (orchestrator が receipt から追記、ADR-0019)
  refute_grep -q "past_topics.json" <<< "$(sed -n '/^## 書き込み先/,/^## 過去テーマ履歴/p' <<< "$prompt")"
  echo "$prompt" | grep -q "## 書き込み先"
  echo "$prompt" | grep -q "機会メモ"   # テンプレート注入
  # 書き込み先の列挙 (ADR-0017): state の brief / pending / 根拠ファイル / run receipt
  echo "$prompt" | grep -q "run receipt"
  echo "$prompt" | grep -q "brief.md"
  echo "$prompt" | grep -q "pending.md"
  echo "$prompt" | grep -q "state/$PICKED/runs/${DR_DATE}.json"
  echo "$prompt" | grep -q "state/$PICKED/runs/${DR_DATE}.md"
  # context_files は選定後に読む候補として別節 (line-brief)
  echo "$prompt" | grep -q "## Line 定義 (config)"
  refute_grep -q "判断基準 (優先順)" <<< "$prompt"  # scoring_criteria は廃止 (ADR-0014)
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
  refute_grep -q "past_topics" <<< "$allowed"
  refute_grep -q "Write(" <<< "$allowed"
  # 無条件 Write/Edit は含まれない
  refute_grep -qE '(^|,)Write(,|$)' <<< "$allowed"
  refute_grep -qE '(^|,)Edit(,|$)' <<< "$allowed"
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

  # 呼2 は対象ノートと verify.json だけを Edit でき、WebFetch (原典照合) は持つが
  # WebSearch・Bash・glob 権限を持たない (ADR-0017)
  local allowed disallowed prompt
  allowed=$(cat "$MOCK_HOME/.allowed_clarity")
  [ "$allowed" = "Read,WebFetch,Edit(//${MOCK_HOME#/}/mock-vault/daily-research/${DR_DATE}_${PICKED}_mock-report.md),Edit(//${MOCK_PROJECT#/}/state/$PICKED/runs/${DR_DATE}.verify.json)" ]
  refute_grep -q "WebSearch" <<< "$allowed"
  refute_grep -q "Bash" <<< "$allowed"
  refute_grep -q '\*\*' <<< "$allowed"          # 単一ファイル限定 — glob を含まない
  refute_grep -q "past_topics" <<< "$allowed"
  # state/ を含む allow は verify.json の 1 件だけ
  [ "$(printf '%s' "$allowed" | tr ',' '\n' | grep -c 'state/')" -eq 1 ]
  printf '%s' "$allowed" | tr ',' '\n' | grep 'state/' | grep -q "runs/${DR_DATE}.verify.json)$"
  disallowed=$(cat "$MOCK_HOME/.disallowed_clarity")
  printf '%s' "$disallowed" | grep -qE '(^|,)WebSearch(,|$)'
  printf '%s' "$disallowed" | grep -qE '(^|,)Bash(,|$)'
  grep -qF "Read(//${MOCK_HOME#/}/.claude/**)" <<< "$disallowed"
  # 呼2 も safe mode + 組み込みツールの集合 (ADR-0019 Decision 2)
  grep -qx -- "--safe-mode" "$MOCK_HOME/.args_clarity"
  grep -A1 -x -- '--tools' "$MOCK_HOME/.args_clarity" | grep -qx "Read,WebFetch,Edit,Write"
  # max-turns 30 / model は config-get の既定 sonnet
  grep -A1 -x -- '--max-turns' "$MOCK_HOME/.args_clarity" | grep -qx 30
  grep -A1 -x -- '--model' "$MOCK_HOME/.args_clarity" | grep -qx sonnet
  prompt=$(cat "$MOCK_HOME/.prompt_clarity")
  echo "$prompt" | grep -q "対象ファイル"
  echo "$prompt" | grep -q "state/$PICKED/runs/${DR_DATE}.verify.json"
  echo "$prompt" | grep -q "書き込みはこの 2 ファイル"
}

@test "E2E clarity: clarity failure is fail-open (report survives, run still succeeds)" {
  echo "clarity-fail" > "$MOCK_HOME/.mock_scenario"

  run_script
  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "WARN: clarity pass failed"
  echo "$log_content" | grep -q "Completed successfully"
  # 呼2 失敗は未検証として出す (silent にしない、ADR-0017)
  echo "$log_content" | grep -q "Line $PICKED is unverified"
  echo "$log_content" | grep -q "未検証: $PICKED"
  notified "未検証: $PICKED"
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
  refute_grep -q "Completed successfully" <<< "$log_content"
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
  refute_grep -q "Line: $PICKED" <<< "$log_content"
  [ ! -f "$MOCK_HOME/.prompt_$PICKED" ]
}

@test "E2E auth: 401 during the line run aborts immediately (no retry, no clarity)" {
  echo "run-401" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -ne 0 ]

  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "returned 401 — aborting"
  refute_grep -q "retrying once" <<< "$log_content"
  [ ! -f "$MOCK_HOME/.prompt_clarity" ]
}

# === Test: 成功化け防止 (is_error / ctl-015) ===

@test "E2E: exit 0 with is_error is reported as Failed (no success masking)" {
  echo "run-iserror" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -ne 0 ]

  local log_content
  log_content=$(get_log)

  refute_grep -q "Completed successfully" <<< "$log_content"
  echo "$log_content" | grep -q "Failed (E_NO_REPORT"
}

@test "E2E: success without report files is reported as Failed (report existence gate)" {
  echo "noreport" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -ne 0 ]

  local log_content
  log_content=$(get_log)

  refute_grep -q "Completed successfully" <<< "$log_content"
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
  refute_grep -q "Clarity pass:" <<< "$(get_log)"
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

# === Test: retry 日の metrics は全 attempt のコストを合算する ===
@test "E2E metrics: a retried line records both attempts' cost in pass2 (fallback_used=true)" {
  echo "run-iserror-once" > "$MOCK_HOME/.mock_scenario"

  run_script
  get_log | grep -q "retrying once"
  run python3 - "$MOCK_PROJECT/metrics.jsonl" << 'PYEOF'
import json, sys
rec = json.loads(open(sys.argv[1]).read().splitlines()[0])
assert rec["fallback_used"] is True, rec
assert abs(rec["pass2"]["cost"] - 0.10) < 1e-9, rec   # 0.05 (失敗) + 0.05 (成功)
assert rec["pass2"]["turns"] == 58, rec                # 55 + 3
PYEOF
  [ "$status" -eq 0 ]
}

# === Test: 試験 seam の run は metrics に source=test で記録され集計から除かれる ===
@test "E2E metrics: DR_FORCE_TRACK run is tagged source=test and excluded from expect-check" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  HOME="$MOCK_HOME" DR_FORCE_TRACK="$OTHER" bash "$MOCK_PROJECT/scripts/daily-research.sh" 2>&1
  run python3 - "$MOCK_PROJECT/metrics.jsonl" << 'PYEOF'
import json, sys
rec = json.loads(open(sys.argv[1]).read().splitlines()[0])
assert rec["source"] == "test", rec
PYEOF
  [ "$status" -eq 0 ]
  # 本番集計 (expect-check) は test レコードを見ない → データ不足
  run bash -c "printf '2026-01-01\treport_count_min >= 1\n' | python3 '$MOCK_PROJECT/scripts/lib/dr_pipeline.py' expect-check '$MOCK_PROJECT/metrics.jsonl'"
  echo "$output" | grep -q "INSUFFICIENT_DATA"
}

# === Test: notify は配送の成否を log に残す (無人 run の唯一の push 経路) ===
@test "E2E notify: every notify call leaves a sent/failed/skipped line in the log" {
  echo "noreport" > "$MOCK_HOME/.mock_scenario"

  run run_script
  # E_NO_REPORT で notify が呼ばれる → 成否いずれかが log に残る
  get_log | grep -qE "notify (sent|failed|skipped)"
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
  if grep -v '^#\|^[[:space:]]*#' "$MOCK_PROJECT/scripts/daily-research.sh" | grep -q 'gtimeout\|TIMEOUT_CMD\|timeout_secs'; then
    false
  fi
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
  refute_grep -q "SUMMARY Run($OTHER):" <<< "$log_content"

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
  refute_grep -q "Line: $PICKED" <<< "$log_content"
  refute_grep -q "Rotation pick:" <<< "$log_content"
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
  refute_grep -q "=== Line:" <<< "$log_content"
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
  refute_grep -q "Rotation pick:" <<< "$log_content"
  echo "$log_content" | grep -q "Line desire report gate passed"
  echo "$log_content" | grep -q "Completed successfully"
  # 輪番なら当日担当だったはずの line は走らない
  refute_grep -q "=== Line: akc" <<< "$log_content"
  refute_grep -q "=== Line: authorship" <<< "$log_content"
}

@test "E2E force-track: DR_FORCE_TRACK not in config fails fast" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run env HOME="$MOCK_HOME" DR_FORCE_TRACK=nonexistent bash "$MOCK_PROJECT/scripts/daily-research.sh"
  [ "$status" -ne 0 ]
  get_log | grep -q "DR_FORCE_TRACK=nonexistent は config.toml に無い"
  [ ! -f "$MOCK_HOME/.prompt_$PICKED" ]
}

# === ADR-0017: 内容状態 / receipt gate / 検証結果 ===

# metrics.jsonl の 1 レコード目に python の assert を当てる (stdin = assert 本文)
assert_metrics() {
  python3 -c '
import json, sys
rec = json.loads(open(sys.argv[1]).read().splitlines()[0])
exec(sys.stdin.read())
' "$MOCK_PROJECT/metrics.jsonl"
}

@test "E2E states: article records STATE, VERIFY, verify.json and a Line states summary" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -eq 0 ]
  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "Line $PICKED state: article"
  echo "$log_content" | grep -q "Line $PICKED report gate passed"
  echo "$log_content" | grep -q "VERIFY $PICKED: {\"supported\": 3, \"partial\": 1, \"unsupported\": 0, \"unverifiable\": 1, \"edits\": 2, \"ran\": true}"
  echo "$log_content" | grep -q "Line states: article=1 brief=0 quiet=0 hold=0 (今朝: $PICKED)"
  notified "今朝のリサーチレポートが完成しました (今朝: $PICKED)\""
  refute_grep -q "unverified" <<< "$log_content"
  [ -f "$MOCK_PROJECT/state/$PICKED/runs/${DR_DATE}.json" ]
  [ -f "$MOCK_PROJECT/state/$PICKED/runs/${DR_DATE}.verify.json" ]
  assert_metrics << 'PY'
assert rec["final_class"] == "OK", rec
assert rec["line_states"] == {"article": 1, "brief": 0, "quiet": 0, "hold": 0, "mismatch": 0, "suspect": 0, "unverified": 0}, rec
assert rec["verification"] == {"supported": 3, "partial": 1, "unsupported": 0, "unverifiable": 1, "edits": 2, "lines_verified": 1}, rec
PY
}

@test "E2E states: brief passes the gate, gets verified, and is labelled (brief)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  echo brief > "$MOCK_HOME/.state_$PICKED"

  run run_script
  [ "$status" -eq 0 ]
  get_log | grep -q "Line $PICKED state: brief"
  get_log | grep -q "Clarity pass ok"
  get_log | grep -q "Line states: article=0 brief=1 quiet=0 hold=0 (今朝: $PICKED(brief))"
  assert_metrics << 'PY'
assert rec["line_states"]["brief"] == 1, rec
# lint は kind: brief を読み、機会メモ / 本文長の soft を免除する
assert rec["lint"]["results"][0]["kind"] == "brief", rec
assert not any("機会メモ" in s for s in rec["lint"]["results"][0]["soft"]), rec
PY
}

@test "E2E states: quiet is a normal outcome (gate passes, no clarity, no-update notify)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  echo quiet > "$MOCK_HOME/.state_$PICKED"

  run run_script
  [ "$status" -eq 0 ]
  local log_content
  log_content=$(get_log)
  echo "$log_content" | grep -q "Line $PICKED state: quiet (reason_code=no_new_evidence) mock reason"
  echo "$log_content" | grep -q "Line $PICKED report gate passed"
  echo "$log_content" | grep -q "Completed successfully"
  refute_grep -q "Clarity pass:" <<< "$log_content"
  refute_grep -q "VERIFY $PICKED" <<< "$log_content"
  refute_grep -q "fetch failure" <<< "$log_content"
  echo "$log_content" | grep -q "Line states: article=0 brief=0 quiet=1 hold=0 (更新なし: $PICKED)"
  notified "今朝は更新なし (更新なし: $PICKED)\""
  [ ! -f "$MOCK_HOME/.prompt_clarity" ]
  assert_metrics << 'PY'
assert rec["final_class"] == "OK", rec
assert rec["line_states"]["quiet"] == 1 and rec["line_states"]["suspect"] == 0, rec
assert rec["verification"] is None, rec
assert rec["clarity_pass"] is None, rec
PY
}

@test "E2E states: hold with an empty pending.md warns but passes" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  echo hold > "$MOCK_HOME/.state_$PICKED"

  run run_script
  [ "$status" -eq 0 ]
  get_log | grep -q "Line $PICKED state: hold"
  get_log | grep -q "hold but state/$PICKED/pending.md is empty"
  get_log | grep -q "Line states: article=0 brief=0 quiet=0 hold=1 (更新なし: $PICKED(hold))"
  assert_metrics << 'PY'
assert rec["line_states"]["hold"] == 1, rec
PY
}

@test "E2E states: hold with a non-empty pending.md does not warn" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  echo hold > "$MOCK_HOME/.state_$PICKED"
  mkdir -p "$MOCK_PROJECT/state/$PICKED"
  echo "- pending question (再開条件: X)" > "$MOCK_PROJECT/state/$PICKED/pending.md"

  run run_script
  [ "$status" -eq 0 ]
  refute_grep -q "pending.md is empty" <<< "$(get_log)"
}

@test "E2E gate: a report without a run receipt fails the line" {
  echo "receipt-missing" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -ne 0 ]
  get_log | grep -q "report gate failed for line $PICKED — no run receipt runs/${DR_DATE}.json (ctl-015)"
  get_log | grep -q "Failed (E_NO_REPORT"
  [ ! -f "$MOCK_HOME/.prompt_clarity" ]
  # retry skip は report だけでも効く (呼1 は 1 回)
  [ "$(cat "$MOCK_HOME/.calls_$PICKED")" -eq 1 ]
}

@test "E2E gate: receipt says article but the run wrote no report — line fails" {
  echo "receipt-article-no-file" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -ne 0 ]
  get_log | grep -q "report gate failed for line $PICKED — receipt status article but no ${DR_DATE}_${PICKED}_\*.md from this run (ctl-015)"
  [ ! -f "$MOCK_HOME/.prompt_clarity" ]
  assert_metrics << 'PY'
assert rec["final_class"] == "E_NO_REPORT", rec
assert sum(rec["line_states"].values()) == 0, rec
PY
}

@test "E2E gate: receipt says quiet but the run wrote a report — file wins (article + mismatch)" {
  echo "receipt-quiet-with-file" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -eq 0 ]
  get_log | grep -q "receipt says quiet but this run wrote ${DR_DATE}_${PICKED}_mock-report.md — treating as article (file wins, mismatch)"
  get_log | grep -q "Line $PICKED state: article"
  get_log | grep -q "Clarity pass ok"
  assert_metrics << 'PY'
assert rec["line_states"]["article"] == 1 and rec["line_states"]["mismatch"] == 1, rec
assert rec["line_states"]["quiet"] == 0, rec
PY
}

@test "E2E gate: an unparsable receipt fails the line" {
  echo "receipt-bad-json" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -ne 0 ]
  get_log | grep -q "report gate failed for line $PICKED — invalid run receipt runs/${DR_DATE}.json (ctl-015)"
  get_log | grep -q "receipt-read: unreadable receipt"
  [ ! -f "$MOCK_HOME/.prompt_clarity" ]
}

@test "E2E gate: a stale receipt from an earlier invocation does not satisfy the gate" {
  echo "noreport" > "$MOCK_HOME/.mock_scenario"
  mkdir -p "$MOCK_PROJECT/state/$PICKED/runs"
  printf '{"date": "%s", "line": "%s", "status": "quiet", "report": null}\n' "$DR_DATE" "$PICKED" \
    > "$MOCK_PROJECT/state/$PICKED/runs/${DR_DATE}.json"
  touch -t 202001010000 "$MOCK_PROJECT/state/$PICKED/runs/${DR_DATE}.json"

  run run_script
  [ "$status" -ne 0 ]
  get_log | grep -q "report gate failed for line $PICKED — no run receipt"
}

@test "E2E retry: a receipt left by a failed attempt 1 skips the retry" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  echo quiet > "$MOCK_HOME/.state_$PICKED"
  # attempt 1 が quiet の receipt を書いた後に非ゼロ exit する: mock 本体を包むラッパー
  mv "$MOCK_HOME/.claude/local/claude" "$MOCK_HOME/.claude/local/claude-real"
  cat > "$MOCK_HOME/.claude/local/claude" << 'EOF'
#!/bin/bash
out=$("$(dirname "$0")/claude-real" "$@"); rc=$?
printf '%s\n' "$out"
case " $* " in *repo-research-protocol.md*) exit 1 ;; esac
exit $rc
EOF
  chmod +x "$MOCK_HOME/.claude/local/claude"

  run run_script
  get_log | grep -q "attempt 1 left a report or receipt — skipping retry"
  [ "$(cat "$MOCK_HOME/.calls_$PICKED")" -eq 1 ]
  get_log | grep -q "Line $PICKED state: quiet"
}

@test "E2E states: verify.json missing marks the line unverified (run still OK)" {
  echo "verify-missing" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -eq 0 ]
  local log_content
  log_content=$(get_log)
  echo "$log_content" | grep -q "Clarity pass ok"
  echo "$log_content" | grep -q "VERIFY $PICKED: {.*\"ran\": false}"
  echo "$log_content" | grep -q "Line $PICKED is unverified"
  notified "今朝のリサーチレポートが完成しました (今朝: $PICKED / 未検証: $PICKED)"
  assert_metrics << 'PY'
assert rec["line_states"]["article"] == 1 and rec["line_states"]["unverified"] == 1, rec
assert rec["verification"]["lines_verified"] == 0, rec
PY
}

@test "E2E states: a stale verify.json from an earlier run is removed before clarity" {
  echo "verify-missing" > "$MOCK_HOME/.mock_scenario"
  mkdir -p "$MOCK_PROJECT/state/$PICKED/runs"
  echo '{"supported": 9, "partial": 0, "unsupported": 0, "unverifiable": 0, "edits": 0}' \
    > "$MOCK_PROJECT/state/$PICKED/runs/${DR_DATE}.verify.json"

  run run_script
  get_log | grep -q "VERIFY $PICKED: {\"supported\": 0, .*\"ran\": false}"
  [ ! -f "$MOCK_PROJECT/state/$PICKED/runs/${DR_DATE}.verify.json" ]
}

@test "E2E states: clarity failure counts as unverified in metrics" {
  echo "clarity-fail" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -eq 0 ]
  assert_metrics << 'PY'
assert rec["line_states"]["unverified"] == 1, rec
assert rec["clarity_pass"]["ok"] is False, rec
PY
}

@test "E2E states: quiet with reason_code fetch_failed is flagged as a suspected fetch failure" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  echo quiet > "$MOCK_HOME/.state_$PICKED"
  echo fetch_failed > "$MOCK_HOME/.reason_code_$PICKED"

  run run_script
  [ "$status" -eq 0 ]
  get_log | grep -q "Line $PICKED quiet looks like a fetch failure (reason_code=fetch_failed, searches=4)"
  notified "今朝は更新なし (更新なし: $PICKED / 取得失敗の疑い: $PICKED)"
  assert_metrics << 'PY'
assert rec["final_class"] == "OK", rec
assert rec["line_states"]["quiet"] == 1 and rec["line_states"]["suspect"] == 1, rec
PY
}

@test "E2E states: hold with zero searches is flagged as a suspected fetch failure" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  echo hold > "$MOCK_HOME/.state_$PICKED"
  touch "$MOCK_HOME/.nosearch_$PICKED"

  run run_script
  [ "$status" -eq 0 ]
  get_log | grep -q "Line $PICKED hold looks like a fetch failure (reason_code=no_new_evidence, searches=0)"
  assert_metrics << 'PY'
assert rec["line_states"]["suspect"] == 1, rec
PY
}

@test "E2E states: partial failure notify lists published, unchanged, and failed lines" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  add_daily_line
  echo quiet > "$MOCK_HOME/.state_$PICKED"
  printf 'desire\n' > "$MOCK_HOME/.fail_tracks"

  run run_script
  [ "$status" -ne 0 ]
  get_log | grep -q "Failed (E_PARTIAL"
  notified "リサーチが一部失敗しました (更新なし: $PICKED / failed: desire)。ログを確認してください。"
}

# === ADR-0017: lines_per_day window ===

@test "E2E window: lines_per_day = 2 runs both lines and line 2 sees line 1's question" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  # [general] に lines_per_day を差し込む (既存 mock config は K=1 のまま)
  python3 - "$MOCK_PROJECT/config.toml" << 'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace('output_dir = "daily-research"\n', 'output_dir = "daily-research"\nlines_per_day = 2\n', 1)
open(p, "w").write(s)
PY

  run run_script
  [ "$status" -eq 0 ]
  local log_content
  log_content=$(get_log)
  echo "$log_content" | grep -q "Rotation pick: akc, authorship (ADR-0010/0017)"
  echo "$log_content" | grep -q "Today's lines: 2"
  echo "$log_content" | grep -q "Line akc report gate passed"
  echo "$log_content" | grep -q "Line authorship report gate passed"
  echo "$log_content" | grep -q "Line states: article=2 brief=0 quiet=0 hold=0 (今朝: akc, authorship)"
  # past-themes は line ごとに再計算 — 後続 line は先行 line の問いを見る (orchestrator が receipt から追記)
  grep -q "mock question for akc — mock scope" "$MOCK_HOME/.prompt_authorship"
  python3 - "$MOCK_PROJECT/past_topics.json" "$DR_DATE" << 'PY'
import json, sys
topics = json.load(open(sys.argv[1]))["topics"]
new = [t for t in topics if t.get("date") == sys.argv[2]]
assert [t["track"] for t in new] == ["akc", "authorship"], new
assert new[0] == {"date": sys.argv[2], "track": "akc", "title": "mock title for akc",
                  "slug": "mock-report", "question": "mock question for akc",
                  "answer_scope": "mock scope"}, new[0]
PY
  refute_grep -q "mock question for authorship" "$MOCK_HOME/.prompt_akc"
  assert_metrics << 'PY'
assert rec["line_states"]["article"] == 2, rec
assert rec["verification"]["lines_verified"] == 2, rec
assert rec["verification"]["supported"] == 6, rec
PY
}


# =============================================================================
# ADR-0018: ecosystem-mode daily line (接地 repo なし)
# =============================================================================

@test "E2E ecosystem: the daily ecosystem line runs after the rotation pick with no target repo" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  add_ecosystem_daily_line

  run run_script
  [ "$status" -eq 0 ]
  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "Rotation pick: $PICKED, eco"
  echo "$log_content" | grep -q "Today's lines: 2"
  echo "$log_content" | grep -q "Line eco report gate passed"
  refute_grep -q "target_repo が存在しない" <<< "$log_content"
  [ ! -f "$MOCK_HOME/.calls_$OTHER" ]   # 輪番の本数は daily line の追加で変わらない
  [ -f "$MOCK_HOME/mock-vault/daily-research/${DR_DATE}_eco_mock-report.md" ]
  [ -f "$MOCK_PROJECT/state/eco/runs/${DR_DATE}.json" ]
}

@test "E2E ecosystem: execution form — cwd is the line state dir, ecosystem protocol, safe mode" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  add_ecosystem_daily_line

  run run_script
  [ "$status" -eq 0 ]

  [ "$(cat "$MOCK_HOME/.cwd_eco")" = "$(cd "$MOCK_PROJECT/state/eco" && pwd -P)" ]
  [[ "$(cat "$MOCK_HOME/.protocol_eco")" == */prompts/ecosystem-research-protocol.md ]]
  grep -qx -- "--safe-mode" "$MOCK_HOME/.args_eco"
  # 境界は repo line と同じ: deny に Bash、書き込みは vault / state / past_topics のみ
  grep -q "Bash" "$MOCK_HOME/.disallowed_eco"
  # cwd が model-writable なので、cwd の設定面 (.claude/ / CLAUDE.md / .mcp.json) を deny する
  grep -qF "Edit(//${MOCK_PROJECT#/}/state/eco/.claude/**)" "$MOCK_HOME/.disallowed_eco"
  grep -qF "Edit(//${MOCK_PROJECT#/}/state/eco/CLAUDE.md)" "$MOCK_HOME/.disallowed_eco"
  grep -qF "Edit(//${MOCK_PROJECT#/}/state/eco/.mcp.json)" "$MOCK_HOME/.disallowed_eco"
  # 運用者の harness と API key の dir は permission 層でも読ませない (全 line 共通、ADR-0019)
  grep -qF "Read(//${MOCK_HOME#/}/.claude/**)" "$MOCK_HOME/.disallowed_eco"
  grep -qF "Read(//${MOCK_HOME#/}/.codex/**)" "$MOCK_HOME/.disallowed_eco"
  grep -qF "Read(//${MOCK_HOME#/}/.config/daily-research/**)" "$MOCK_HOME/.disallowed_eco"
  # state のうち書けるのは pending.md / runs/ / watchlist だけ (brief は静的、ADR-0019 Decision 3)
  grep -qF "Edit(//${MOCK_PROJECT#/}/state/eco/pending.md)" "$MOCK_HOME/.allowed_eco"
  grep -qF "Edit(//${MOCK_PROJECT#/}/state/eco/runs/**)" "$MOCK_HOME/.allowed_eco"
  grep -qF "Edit(//${MOCK_PROJECT#/}/state/eco/watched-sources.md)" "$MOCK_HOME/.allowed_eco"
  refute_grep -qF "Edit(//${MOCK_PROJECT#/}/state/eco/**)" "$MOCK_HOME/.allowed_eco"
  # repo line は watchlist を書かない
  refute_grep -q "watched-sources" "$MOCK_HOME/.allowed_$PICKED"
  grep -qF "Edit(//${MOCK_PROJECT#/}/state/$PICKED/pending.md)" "$MOCK_HOME/.allowed_$PICKED"

  # repo line の実行形は不変
  [ "$(cat "$MOCK_HOME/.cwd_$PICKED")" = "$(cd "$MOCK_HOME/mock-repos/authorship-strategy" && pwd -P)" ]
  [[ "$(cat "$MOCK_HOME/.protocol_$PICKED")" == */prompts/repo-research-protocol.md ]]
  # safe mode・組み込みツールの集合・共通 deny は repo line にも効く (ADR-0019 Decision 2)
  grep -qx -- "--safe-mode" "$MOCK_HOME/.args_$PICKED"
  grep -A1 -x -- '--tools' "$MOCK_HOME/.args_$PICKED" | grep -qx "WebSearch,WebFetch,Read,Glob,Grep,Edit,Write"
  grep -A1 -x -- '--tools' "$MOCK_HOME/.args_eco" | grep -qx "WebSearch,WebFetch,Read,Glob,Grep,Edit,Write"
  [ "$(cat "$MOCK_HOME/.disallowed_$PICKED")" = "Bash,Task,NotebookEdit,Read(//${MOCK_HOME#/}/.claude/**),Read(//${MOCK_HOME#/}/.codex/**),Read(//${MOCK_HOME#/}/.config/daily-research/**)" ]
}

@test "E2E ecosystem: the prompt carries no repo wording; the repo line's prompt is unchanged" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  add_ecosystem_daily_line

  run run_script
  [ "$status" -eq 0 ]

  grep -q "^- line (track): eco$" "$MOCK_HOME/.prompt_eco"
  grep -q "^- mode: ecosystem" "$MOCK_HOME/.prompt_eco"
  grep -q "focus: Ecosystem line focus" "$MOCK_HOME/.prompt_eco"
  grep -q "エコシステム観測プロトコル" "$MOCK_HOME/.prompt_eco"
  refute_grep -q "research repo" "$MOCK_HOME/.prompt_eco"
  refute_grep -q "per-repo" "$MOCK_HOME/.prompt_eco"
  refute_grep -q "選定後に読む候補" "$MOCK_HOME/.prompt_eco"
  refute_grep -q "この repo" "$MOCK_HOME/.prompt_eco"   # ecosystem テンプレートが注入されている

  grep -q "作業ディレクトリ = この line の research repo" "$MOCK_HOME/.prompt_$PICKED"
  grep -q "per-repo リサーチ・プロトコル" "$MOCK_HOME/.prompt_$PICKED"
  refute_grep -q "エコシステム" "$MOCK_HOME/.prompt_$PICKED"
}

@test "E2E ecosystem: article / brief / quiet / hold all pass the existing receipt gate" {
  add_ecosystem_daily_line
  mkdir -p "$MOCK_PROJECT/state/eco"
  echo "resume condition" > "$MOCK_PROJECT/state/eco/pending.md"
  local st
  for st in article brief quiet hold; do
    echo "normal" > "$MOCK_HOME/.mock_scenario"
    echo "$st" > "$MOCK_HOME/.state_eco"
    rm -rf "$MOCK_HOME/mock-vault/daily-research" "$MOCK_PROJECT/state/eco/runs" "$MOCK_PROJECT/logs"
    mkdir -p "$MOCK_PROJECT/logs"

    run run_script
    [ "$status" -eq 0 ]
    local log_content
    log_content=$(get_log)
    echo "$log_content" | grep -q "Line eco state: $st"
    echo "$log_content" | grep -q "Line eco report gate passed"
    case "$st" in
      article|brief) [ -f "$MOCK_PROJECT/state/eco/runs/${DR_DATE}.verify.json" ] ;;
      quiet|hold)    [ ! -f "$MOCK_HOME/mock-vault/daily-research/${DR_DATE}_eco_mock-report.md" ] ;;
    esac
  done
}

@test "E2E ecosystem: DR_FORCE_TRACK can run the ecosystem line alone" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  add_ecosystem_daily_line

  DR_FORCE_TRACK=eco run run_script
  [ "$status" -eq 0 ]
  [ -f "$MOCK_HOME/.calls_eco" ]
  [ ! -f "$MOCK_HOME/.calls_$PICKED" ]
  get_log | grep -q "Line eco report gate passed"
}
