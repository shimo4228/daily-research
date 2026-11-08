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
  # 呼3 の 2 段 (ADR-0020) も mock は protocol の名前で識別する
  cp "$REAL_PROJECT_DIR/prompts/audit-protocol.md" "$REAL_PROJECT_DIR/prompts/audit-confirm-protocol.md" "$MOCK_PROJECT/prompts/"
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
  # effort の env (lib/env.sh が unset する) が claude まで届いたか
  printf '%s' "${CLAUDE_CODE_EFFORT_LEVEL-unset}" > "$MOCK_HOME_DIR/.effort_env_$TRACK"
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
  # event_date seam (H17): .event_date_<track> の中身 (既定 = DR_DATE)。absent なら key を書かない (旧 receipt)
  EVENT_DATE=$(cat "$MOCK_HOME_DIR/.event_date_$TRACK" 2>/dev/null || echo "$DR_DATE")
  write_receipt() {  # $1 = status, $2 = report basename or empty
    local report_json=null event_json=""
    [ -n "$2" ] && report_json="\"$2\""
    [ "$EVENT_DATE" != "absent" ] && event_json=", \"event_date\": \"$EVENT_DATE\""
    printf '{"date": "%s", "line": "%s", "status": "%s", "report": %s, "question": "mock question for %s", "reason": "mock reason", "reason_code": "%s", "answer_scope": "mock scope", "title": "mock title for %s"%s}\n' \
      "$DR_DATE" "$TRACK" "$1" "$report_json" "$TRACK" "$REASON_CODE" "$TRACK" "$event_json" > "$RECEIPT"
  }

  # pending.md 追記 seam (H02): .pending_add_<track> があれば state の pending.md に追記する
  if [ -f "$MOCK_HOME_DIR/.pending_add_$TRACK" ] && [ -n "$RECEIPT" ]; then
    cat "$MOCK_HOME_DIR/.pending_add_$TRACK" >> "${RECEIPT%/runs/*}/pending.md"
  fi

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
          elif [ -f "$MOCK_HOME_DIR/.report_$TRACK" ]; then
            cp "$MOCK_HOME_DIR/.report_$TRACK" "$REPORT_DIR/$REPORT_NAME"
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
  # 本文の追記 seam (H05): .report_body_<track> があれば、書いたレポートの末尾に足す (clarity-scan 用)
  if [ -f "$MOCK_HOME_DIR/.report_body_$TRACK" ] && [ -f "$REPORT_DIR/$REPORT_NAME" ]; then
    cat "$MOCK_HOME_DIR/.report_body_$TRACK" >> "$REPORT_DIR/$REPORT_NAME"
  fi

  # 検索回数: 実出力と同じく modelUsage.<model>.webSearchRequests に載せる。
  # .nosearch_<track> があれば検索 0 回の run を返す (quiet-suspect テスト用)
  SEARCH_USAGE=',"modelUsage":{"mock-haiku":{"webSearchRequests":4}}'
  [ -f "$MOCK_HOME_DIR/.nosearch_$TRACK" ] && SEARCH_USAGE=''
  # num_turns seam (H14): .turns_<track> があればその値 (既定 3)
  TURNS=$(cat "$MOCK_HOME_DIR/.turns_$TRACK" 2>/dev/null || echo 3)
  echo '[{"type":"assistant","message":{"content":[]}},{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.05,"num_turns":'"$TURNS"',"duration_ms":30000,"usage":{"input_tokens":2000,"output_tokens":800}'"$SEARCH_USAGE"'}]'
  exit 0
fi

# --- 呼2: clarity 改稿 + 原典照合 (verification-protocol.md、ADR-0010/0017) ---
if [[ "$PROTOCOL" == *verification-protocol.md ]]; then
  printf '%s' "$PROMPT" > "$MOCK_HOME_DIR/.prompt_clarity"
  printf '%s' "$ALLOWED" > "$MOCK_HOME_DIR/.allowed_clarity"
  printf '%s' "$DISALLOWED" > "$MOCK_HOME_DIR/.disallowed_clarity"
  printf '%s\n' "$@" > "$MOCK_HOME_DIR/.args_clarity"
  printf '%s' "${CLAUDE_CODE_EFFORT_LEVEL-unset}" > "$MOCK_HOME_DIR/.effort_env_clarity"

  if [[ "$SCENARIO" == "clarity-fail" ]]; then
    echo "ERROR: simulated clarity failure" >&2
    exit 1
  fi

  # verify.json はプロンプトに渡されたパスへ書く (verify-missing は書かない)
  if [[ "$SCENARIO" != "verify-missing" ]]; then
    VERIFY=$(printf '%s\n' "$PROMPT" | grep -oE '/[^ ]*/runs/[0-9-]+\.verify\.json' | head -1)
    [ -n "$VERIFY" ] && printf '{"supported": 3, "partial": 1, "unsupported": 0, "unverifiable": 1, "edits": 2}\n' > "$VERIFY"
  fi

  # 改稿 seam (H07): .clarity_post があれば原稿をその内容で置き換え、.clarity_result があれば
  # その本文を result (完了報告) に載せる
  NOTE=$(printf '%s\n' "$PROMPT" | sed -n 's/^対象ファイル (原稿): //p' | head -1)
  [ -f "$MOCK_HOME_DIR/.clarity_post" ] && [ -n "$NOTE" ] && cp "$MOCK_HOME_DIR/.clarity_post" "$NOTE"
  RESULT_FILE="$MOCK_HOME_DIR/.clarity_result"
  [ -f "$RESULT_FILE" ] || RESULT_FILE=/dev/null
  python3 -c '
import json, sys
print(json.dumps([{"type": "assistant", "message": {"content": []}}, {"type": "result", "subtype": "success", "is_error": False, "total_cost_usd": 0.02, "num_turns": 2, "duration_ms": 8000, "usage": {"input_tokens": 1500, "output_tokens": 300}, "result": open(sys.argv[1]).read()}]))
' "$RESULT_FILE"
  exit 0
fi

# --- 呼3 第 2 段: 候補 1 件の独立確認 (audit-confirm-protocol.md、ADR-0020) ---
# 判定 seam: .confirm_verdict (A の判定、既定 contradicts) と .confirm_rv (置き換え文の判定、既定 consistent)。
# parts は AUDIT_SENTENCE の「3 か国」を誤り、AUDIT_FIXED の「4 か国」を訂正とする。呼び出しごとに prompt を
# .prompt_confirm に追記する
if [[ "$PROTOCOL" == *audit-confirm-protocol.md ]]; then
  printf '%s\n----\n' "$PROMPT" >> "$MOCK_HOME_DIR/.prompt_confirm"
  printf '%s\n' "$@" > "$MOCK_HOME_DIR/.args_confirm"
  printf '%s' "$DISALLOWED" > "$MOCK_HOME_DIR/.disallowed_confirm"
  VERDICT=$(cat "$MOCK_HOME_DIR/.confirm_verdict" 2>/dev/null || echo contradicts)
  RV=$(cat "$MOCK_HOME_DIR/.confirm_rv" 2>/dev/null || echo consistent)
  python3 -c '
import json, sys
parts = [{"wrong": "3 か国", "fixed": "4 か国", "source_quote": "q", "correct_value": "v"}]
final = json.dumps({"verdict": sys.argv[1], "replacement_verdict": sys.argv[2], "parts": parts, "url_read": "u"})
print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "total_cost_usd": 0.05, "num_turns": 4, "duration_ms": 9000, "usage": {"input_tokens": 900, "output_tokens": 100}, "result": final}))
' "$VERDICT" "$RV"
  exit 0
fi

# --- 呼3 第 1 段: ノート全体の照合 (audit-protocol.md、ADR-0020) ---
# 最終メッセージ seam: .audit_result (無ければ食い違い 0 件の JSON)。audit-fail は呼び出しの失敗
if [[ "$PROTOCOL" == *audit-protocol.md ]]; then
  printf '%s' "$PROMPT" > "$MOCK_HOME_DIR/.prompt_audit"
  printf '%s\n' "$@" > "$MOCK_HOME_DIR/.args_audit"
  printf '%s' "$ALLOWED" > "$MOCK_HOME_DIR/.allowed_audit"
  printf '%s' "$DISALLOWED" > "$MOCK_HOME_DIR/.disallowed_audit"
  if [[ "$SCENARIO" == "audit-fail" ]]; then
    echo "ERROR: simulated audit failure" >&2
    exit 1
  fi
  RESULT_FILE="$MOCK_HOME_DIR/.audit_result"
  if [ ! -f "$RESULT_FILE" ]; then
    RESULT_FILE="$MOCK_HOME_DIR/.audit_result_default"
    printf '%s' '{"claims_checked": 4, "supported": 4, "unverifiable": [], "discrepancies": []}' > "$RESULT_FILE"
  fi
  python3 -c '
import json, sys
print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "total_cost_usd": 0.3, "num_turns": 12, "duration_ms": 60000, "usage": {"input_tokens": 9000, "output_tokens": 900}, "result": open(sys.argv[1]).read()}))
' "$RESULT_FILE"
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

# PATH 先頭 ($HOME/.claude/local) に timeout の spy を置く: 呼び出しごとに引数を 1 行
# ($*) で $MOCK_HOME/.timeout_calls に追記し、本物の timeout へ渡す (実時間で待たずに配線を見る)
install_timeout_spy() {
  local real_timeout; real_timeout=$(command -v timeout)
  printf '#!/bin/bash\necho "$*" >> "%s/.timeout_calls"\nexec "%s" "$@"\n' "$MOCK_HOME" "$real_timeout" \
    > "$MOCK_HOME/.claude/local/timeout"
  chmod +x "$MOCK_HOME/.claude/local/timeout"
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

@test "E2E turns: call 1 gets --max-turns from CALL1_MAX_TURNS; a success above the cap is a success (H14)" {
  # live では --max-turns 55 で num_turns 59 の success がある。num_turns は上限切れの判定に使わない
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  echo 59 > "$MOCK_HOME/.turns_$PICKED"
  run run_script
  [ "$status" -eq 0 ]
  grep -A1 -x -- '--max-turns' "$MOCK_HOME/.args_$PICKED" | grep -qx 55
  get_log | grep -q "SUMMARY Run($PICKED):.* turns=59 "
  get_log | grep -q "Line $PICKED report gate passed"
  refute_grep -q "WARN: Line $PICKED call 1 used" <<< "$(get_log)"
}

# === Test: effort (呼1 / 呼2 の --effort を固定して記録する) ===

# 引数の記録 (.args_*) で --effort の直後の値
effort_arg() {
  grep -A1 -x -- '--effort' "$MOCK_HOME/.args_$1" | sed -n 2p
}

@test "E2E effort: call 1 and call 2 get --effort from the defaults; the log and metrics record them" {
  # 既定は flag を渡す前の実効値 (呼1 は運用者の settings の Opus の high、呼2 は Sonnet の既定 medium)
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  run run_script
  [ "$status" -eq 0 ]
  [ "$(effort_arg "$PICKED")" = "high" ]
  [ "$(effort_arg clarity)" = "medium" ]
  get_log | grep -qF "Effort: call1 high (model opus), call2 medium (model sonnet)"
  run python3 - "$MOCK_PROJECT/metrics.jsonl" << 'PYEOF'
import json, sys
rec = json.loads(open(sys.argv[1]).read().splitlines()[0])
assert rec["effort"] == {"call1": "high", "call2": "medium"}, rec
PYEOF
  [ "$status" -eq 0 ]
}

@test "E2E effort: [effort] in config.toml overrides each call's level" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  printf '\n[effort]\ncall1 = "xhigh"\ncall2 = "low"\n' >> "$MOCK_PROJECT/config.toml"
  run run_script
  [ "$status" -eq 0 ]
  [ "$(effort_arg "$PICKED")" = "xhigh" ]
  [ "$(effort_arg clarity)" = "low" ]
  grep -qF '"effort": {"call1": "xhigh", "call2": "low"}' "$MOCK_PROJECT/metrics.jsonl"
}

@test "E2E effort: an inherited CLAUDE_CODE_EFFORT_LEVEL reaches neither call (it outranks --effort)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  export CLAUDE_CODE_EFFORT_LEVEL=max
  run run_script
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_HOME/.effort_env_$PICKED")" = "unset" ]
  [ "$(cat "$MOCK_HOME/.effort_env_clarity")" = "unset" ]
  [ "$(effort_arg "$PICKED")" = "high" ]
}

@test "E2E effort: an invalid [effort] value stops before any line run" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  printf '\n[effort]\ncall1 = "hgih"\n' >> "$MOCK_PROJECT/config.toml"
  run run_script
  [ "$status" -eq 1 ]
  [ ! -f "$MOCK_HOME/.prompt_$PICKED" ]
  get_log | grep -qF '[effort].call1 must be one of low, medium, high, xhigh, max'
  get_log | grep -qF 'ERROR: [effort] in config.toml is invalid'
  notified "config.toml の [effort] に誤りがあります"
}

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
  notified "config.toml の設定に誤りがあります"
}

@test "E2E: repos written as a single table stops before any line run instead of dropping the line" {
  # [[tracks.akc.repos]] を [tracks.akc.repos] と書き損じた config。以前は akc が輪番から黙って消え、
  # authorship だけで rc 0 の朝になっていた
  sed -i '' 's/^\[\[tracks\.akc\.repos\]\]$/[tracks.akc.repos]/' "$MOCK_PROJECT/config.toml"
  grep -q '^\[tracks\.akc\.repos\]$' "$MOCK_PROJECT/config.toml"

  run run_script
  [ "$status" -ne 0 ]

  local log_content
  log_content=$(get_log)
  echo "$log_content" | grep -q "config.toml schema check failed"
  echo "$log_content" | grep -qF '[tracks.akc].repos must be an array of tables ([[tracks.akc.repos]])'
  [ ! -f "$MOCK_HOME/.prompt_authorship" ]
  [ ! -f "$MOCK_HOME/.prompt_akc" ]
  # 旧 schema 以外の誤りでも、通知と log の案内は「旧 schema」と決めつけない (理由は log の直前の行)
  notified "config.toml の設定に誤りがあります"
  refute_grep -qF "旧 schema" "$MOCK_HOME/.notify_log"
  refute_grep -qF "legacy schema?" <<< "$log_content"
}

# === Test: Absolute path resolution ===

@test "E2E: CLAUDE_CMD resolves to absolute path in .claude/local" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run_script
  local log_content
  log_content=$(get_log)

  echo "$log_content" | grep -q "DEBUG: CLAUDE_CMD=$MOCK_HOME/.claude/local/claude"
}

@test "E2E: claude --version runs under timeout -k (a hung binary cannot hold the lock)" {
  # --version は lock 取得後に走る。timeout が無いと、更新途中で壊れた binary や起動時に固まる
  # claude で run が戻らず、翌朝以降の run が全部 "Another instance is running" になる
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  install_timeout_spy

  run_script
  grep -qE "^-k [0-9]+ [0-9]+ $MOCK_HOME/.claude/local/claude --version\$" "$MOCK_HOME/.timeout_calls"
}

@test "E2E pass3: the vault ingest runs under timeout -k with a limit above the ingest's own claude timeout" {
  # vault の daily_wiki_ingest.sh は内側の claude を timeout 2700 (-k なし) で回す。SIGTERM を無視する
  # claude で ingest が戻らないと、lock を握ったまま run が終わらず翌朝以降が全部 skip になる
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  install_timeout_spy
  mkdir -p "$MOCK_HOME/mock-vault/scripts"
  printf '#!/bin/bash\necho "ingest stub for $1"\n' > "$MOCK_HOME/mock-vault/scripts/daily_wiki_ingest.sh"
  chmod +x "$MOCK_HOME/mock-vault/scripts/daily_wiki_ingest.sh"

  run_script
  get_log | grep -q "ingest stub for $DR_DATE"
  local call
  call=$(grep -E "^-k [0-9]+ [0-9]+ bash $MOCK_HOME/mock-vault/scripts/daily_wiki_ingest.sh $DR_DATE\$" "$MOCK_HOME/.timeout_calls")
  [ "$(echo "$call" | cut -d' ' -f3)" -gt 2700 ]
}

# Pass 3 の ingest stub: vault の daily_wiki_ingest.sh と同じ式 (${WIKI_INGEST_TIMEOUT:-2700}) で内側の上限を
# 決めて .inner_limit に記録する。pass3_outer_limit は timeout spy が見た外側の上限 (秒)
install_ingest_stub() {
  mkdir -p "$MOCK_HOME/mock-vault/scripts"
  printf '#!/bin/bash\necho "${WIKI_INGEST_TIMEOUT:-2700}" > "%s/.inner_limit"\n' "$MOCK_HOME" \
    > "$MOCK_HOME/mock-vault/scripts/daily_wiki_ingest.sh"
  chmod +x "$MOCK_HOME/mock-vault/scripts/daily_wiki_ingest.sh"
}
pass3_outer_limit() {
  grep -E "^-k [0-9]+ [0-9]+ bash $MOCK_HOME/mock-vault/scripts/daily_wiki_ingest.sh $DR_DATE\$" \
    "$MOCK_HOME/.timeout_calls" | cut -d' ' -f3
}

@test "E2E pass3: a larger WIKI_INGEST_TIMEOUT raises the outer limit above it (the outer timeout does not cut first)" {
  # 外側を 3600 に固定していた頃は、WIKI_INGEST_TIMEOUT >= 3570 で正常に進んでいる ingest を外側が先に切った
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  install_timeout_spy
  install_ingest_stub
  export WIKI_INGEST_TIMEOUT=5000

  run_script
  [ "$(cat "$MOCK_HOME/.inner_limit")" = "5000" ]   # 環境はそのまま ingest に渡る
  [ "$(pass3_outer_limit)" -gt 5000 ]
  get_log | grep -qF "Pass 3 outer timeout: $(pass3_outer_limit)s (ingest's claude 5000s + "
}

@test "E2E pass3: WIKI_INGEST_TIMEOUT with a unit suffix is read as a duration" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  install_timeout_spy
  install_ingest_stub
  export WIKI_INGEST_TIMEOUT=90m   # coreutils timeout の DURATION = 5400 秒

  run_script
  [ "$(pass3_outer_limit)" -gt 5400 ]
  get_log | grep -qF "(ingest's claude 5400s + "
}

@test "E2E pass3: an unreadable WIKI_INGEST_TIMEOUT warns and falls back to the vault default" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  install_timeout_spy
  install_ingest_stub
  export WIKI_INGEST_TIMEOUT=soon

  run_script
  [ "$(pass3_outer_limit)" -gt 2700 ]
  get_log | grep -qF "WARN: WIKI_INGEST_TIMEOUT=soon"
  get_log | grep -qF "(ingest's claude 2700s + "
}

@test "E2E pass3: a decimal WIKI_INGEST_TIMEOUT is read as coreutils timeout reads it (the outer timeout does not cut first)" {
  # 整数だけを読んでいた頃は 1.5h (timeout では 5400 秒) を読めずに既定 2700 から外側 3600 を導き、外側が先に切った
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  install_timeout_spy
  install_ingest_stub
  export WIKI_INGEST_TIMEOUT=1.5h

  run_script
  [ "$(pass3_outer_limit)" -gt 5400 ]
  get_log | grep -qF "(ingest's claude 5400s + "
  refute_grep -F "WARN: WIKI_INGEST_TIMEOUT" "$MOCK_PROJECT/logs/$DR_DATE.log"
}

@test "E2E pass3: a WIKI_INGEST_TIMEOUT too large for shell arithmetic warns and Pass 3 still runs" {
  # 9 桁を超える値は外側の上限の足し算が bash の整数で負に溢れ、timeout が 125 で Pass 3 を走らせなかった
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  install_timeout_spy
  install_ingest_stub
  export WIKI_INGEST_TIMEOUT=9223372036854775807

  run_script
  [ "$(pass3_outer_limit)" -gt 2700 ]
  [ -f "$MOCK_HOME/.inner_limit" ]   # ingest が走った
  get_log | grep -qF "WARN: WIKI_INGEST_TIMEOUT=9223372036854775807"
  get_log | grep -qF "(ingest's claude 2700s + "
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
base = {k: rec["verification"][k] for k in ("supported", "partial", "unsupported", "unverifiable", "edits", "lines_verified")}
assert base == {"supported": 3, "partial": 1, "unsupported": 0, "unverifiable": 1, "edits": 2, "lines_verified": 1}, rec
assert rec["verification"]["diff_lines"] == 1 and rec["verification"]["diff_spans"] == 0, rec
PY
}

@test "E2E event: the receipt's event_date becomes event_age_days for the line (H17)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  echo "2026-08-01" > "$MOCK_HOME/.event_date_$PICKED"

  run run_script
  [ "$status" -eq 0 ]
  get_log | grep -q "Line $PICKED event_date: 2026-08-01"
  refute_grep -q "receipt-event-date: WARN" <<< "$(get_log)"
  assert_metrics << 'PY'
assert list(rec["event_age_days"].values()) == [12], rec  # DR_DATE 2026-08-13 − 2026-08-01
PY
}

@test "E2E event: a receipt without event_date (old contract) passes the gate and counts as unknown (H17)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  echo "absent" > "$MOCK_HOME/.event_date_$PICKED"

  run run_script
  [ "$status" -eq 0 ]
  local log_content
  log_content=$(get_log)
  echo "$log_content" | grep -q "Line $PICKED report gate passed"
  echo "$log_content" | grep -q "receipt-event-date: WARN receipt has no event_date"
  echo "$log_content" | grep -q "Line $PICKED event_date: unknown"
  assert_metrics << 'PY'
assert rec["final_class"] == "OK", rec
assert list(rec["event_age_days"].values()) == [None], rec
PY
}

@test "E2E clarity: clarity-scan candidates go to the end of the call-2 prompt and are counted before and after (H05)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  # 3 行目 = 初出に説明の無い HN と、138 字の文
  printf '\nHN の話と、%s。\n\n## ソース\n\n- [x](https://x.example)\n' "$(printf 'あ%.0s' {1..130})" \
    > "$MOCK_HOME/.report_body_$PICKED"

  run run_script
  [ "$status" -eq 0 ]
  local prompt
  prompt=$(cat "$MOCK_HOME/.prompt_clarity")
  echo "$prompt" | grep -qF -- "- 初出に説明の無い略語: HN (3 行目)"
  echo "$prompt" | grep -qF -- "- 120 字を超える文: 3 行目 (138 字)"
  # 候補の節は書き込み先の注記の後 (プロンプトの末尾) に置く
  [ "$(grep -n '書き込みはこの 2 ファイル' <<< "$prompt" | cut -d: -f1)" -lt "$(grep -n '機械が拾った候補' <<< "$prompt" | cut -d: -f1)" ]
  get_log | grep -qF "CLARITY_SCAN $PICKED: before {\"undefined_terms\": 1, \"long_sentences\": 1, \"body_headings\": 0} after {\"undefined_terms\": 1, \"long_sentences\": 1, \"body_headings\": 0}"
  assert_metrics << 'PY'
v = rec["verification"]
assert v["cscan_lines"] == 1 and v["clarity_undef_before"] == 1 and v["clarity_undef_after"] == 1, v
assert v["clarity_long_before"] == 1 and v["clarity_long_after"] == 1, v
PY
}

@test "E2E clarity: a note without candidates leaves the call-2 prompt unchanged and still records zero counts (H05)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -eq 0 ]
  refute_grep -q "機械が拾った候補" "$MOCK_HOME/.prompt_clarity"
  [ "$(tail -c 60 "$MOCK_HOME/.prompt_clarity")" = "$(printf '%s' '書き込みはこの 2 ファイル (原稿と検証結果) だけ。これ以外への書き込みは許可されていない。' | tail -c 60)" ]
  get_log | grep -qF "CLARITY_SCAN $PICKED: before {\"undefined_terms\": 0, \"long_sentences\": 0, \"body_headings\": 0} after "
  refute_grep -q "clarity-scan failed" <<< "$(get_log)"
}

@test "E2E clarity: a clarity-scan failure is fail-open (call 2 runs without candidates, no CSCAN) (H05)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  printf '\nHN \xff\xfe\n' > "$MOCK_HOME/.report_body_$PICKED"   # UTF-8 でない byte で scan が読めない

  run run_script
  [ "$status" -eq 0 ]
  local log_content
  log_content=$(get_log)
  echo "$log_content" | grep -q "WARN: Line $PICKED clarity-scan failed — call 2 runs without machine candidates"
  echo "$log_content" | grep -q "WARN: Line $PICKED clarity-scan counts missing (non-fatal)"
  echo "$log_content" | grep -q "Clarity pass ok"
  refute_grep -q "機械が拾った候補" "$MOCK_HOME/.prompt_clarity"
  assert_metrics << 'PY'
assert "cscan_lines" not in rec["verification"], rec
PY
}

@test "E2E clarity: a pre-verify copy and verify-diff record call 2's real edits and flag self-report errors (H07)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  printf -- '---\nkind: article\n---\n\n# mock report for %s\n\n書き換えた文。\n\n## ソース\n- [n](https://new.example/x)\n' "$PICKED" > "$MOCK_HOME/.clarity_post"
  printf -- '- 検証: 5 件 (supported 4 / partial 1 / unsupported 0 / unverifiable 0)、訂正 span 2\n- 修正 span 合計: 2\n' > "$MOCK_HOME/.clarity_result"

  run run_script
  [ "$status" -eq 0 ]
  local log_content pre="$MOCK_PROJECT/state/$PICKED/pre-verify/${DR_DATE}.md"
  log_content=$(get_log)

  # 改稿前の写しは呼1 が書いた原稿そのもの (呼2 の後も残る)
  [ "$(cat "$pre")" = "# mock report for $PICKED" ]
  grep -q "書き換えた文" "$MOCK_HOME/mock-vault/daily-research/${DR_DATE}_${PICKED}_mock-report.md"
  echo "$log_content" | grep -q "VERIFY_DIFF $PICKED: {\"diff_spans\": "
  # verify.json (supported 3 / unverifiable 1) と完了報告 (supported 4 / unverifiable 0) の食い違い
  echo "$log_content" | grep -q "WARN: Line $PICKED clarity pass: verify.json と完了報告の件数が食い違う (supported 3≠4, unverifiable 1≠0)"
  echo "$log_content" | grep -q "WARN: Line $PICKED clarity pass: frontmatter が改稿された"
  echo "$log_content" | grep -q "WARN: Line $PICKED clarity pass: 原稿に無かった URL が 1 件増えた"
  # 写しはモデルの書き込み先ではない: 呼2 の allow にもプロンプトにも現れない (呼1 の allow も不変)
  refute_grep -q "pre-verify" "$MOCK_HOME/.allowed_clarity"
  refute_grep -q "pre-verify" "$MOCK_HOME/.prompt_clarity"
  refute_grep -q "pre-verify" "$MOCK_HOME/.prompt_$PICKED"
  refute_grep -q "pre-verify" "$MOCK_HOME/.allowed_$PICKED"
  # 呼2 の deny が写しの置き場を塞ぐ
  grep -qF "Edit(//${MOCK_PROJECT#/}/state/$PICKED/pre-verify/**)" "$MOCK_HOME/.disallowed_clarity"
  assert_metrics << 'PY'
v = rec["verification"]
assert v["diff_lines"] == 1 and v["diff_spans"] >= 1, v
assert v["diff_report_mismatch"] == 1 and v["diff_frontmatter_changed"] == 1 and v["diff_new_urls"] == 1, v
PY
}

@test "E2E clarity: an unchanged note gives a zero diff and no clarity WARN (H07)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -eq 0 ]
  local log_content
  log_content=$(get_log)
  echo "$log_content" | grep -q "VERIFY_DIFF $PICKED: {\"diff_spans\": 0, "
  refute_grep -q "clarity pass: " <<< "$log_content"
  [ -f "$MOCK_PROJECT/state/$PICKED/pre-verify/${DR_DATE}.md" ]
}

@test "E2E clarity: a directory squatting on the pre-verify path is replaced by the copy (H07)" {
  # 写しの path に dir が先にある (注入された呼1 か前の run の残り) と、cp は中へ写して成功を返す。
  # SH は rm -rf してから写し、通常ファイルであることを確かめる — verify-diff は改稿前の原稿と比べる
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  local pre="$MOCK_PROJECT/state/$PICKED/pre-verify/${DR_DATE}.md"
  mkdir -p "$pre/inner"
  echo decoy > "$pre/inner/x.md"

  run run_script
  [ "$status" -eq 0 ]
  [ -f "$pre" ]
  [ "$(cat "$pre")" = "# mock report for $PICKED" ]
  get_log | grep -q "VERIFY_DIFF $PICKED: {\"diff_spans\": 0, "
  refute_grep -q "pre-verify copy failed" <<< "$(get_log)"
}

@test "E2E clarity: a symlinked pre-verify dir is unlinked and recreated, the link target is untouched (H07)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  mkdir -p "$MOCK_HOME/outside"
  echo victim > "$MOCK_HOME/outside/${DR_DATE}.md"
  mkdir -p "$MOCK_PROJECT/state/$PICKED"
  ln -s "$MOCK_HOME/outside" "$MOCK_PROJECT/state/$PICKED/pre-verify"

  run run_script
  [ "$status" -eq 0 ]
  [ ! -L "$MOCK_PROJECT/state/$PICKED/pre-verify" ]
  [ -f "$MOCK_PROJECT/state/$PICKED/pre-verify/${DR_DATE}.md" ]
  [ "$(cat "$MOCK_HOME/outside/${DR_DATE}.md")" = "victim" ]
  get_log | grep -q "VERIFY_DIFF $PICKED: "
}

@test "E2E clarity: a symlinked pre-verify dir that cannot be unlinked gets no copy; call 2 still runs (H07)" {
  # rm -f が失敗して link が残ると、rm -rf "<dir>/<date>.md" は link をたどって state の外の file を消す。
  # 失敗を作れないので、PATH の先頭 ($HOME/.claude/local) の rm の shim がその link の rm -f だけを失敗させる
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  mkdir -p "$MOCK_HOME/outside"
  echo victim > "$MOCK_HOME/outside/${DR_DATE}.md"
  mkdir -p "$MOCK_PROJECT/state/$PICKED"
  ln -s "$MOCK_HOME/outside" "$MOCK_PROJECT/state/$PICKED/pre-verify"
  local real_rm; real_rm=$(command -v rm)
  printf '#!/bin/bash\nif [ "$1" = "-f" ] && [[ "$2" == */state/%s/pre-verify ]]; then exit 1; fi\nexec "%s" "$@"\n' \
    "$PICKED" "$real_rm" > "$MOCK_HOME/.claude/local/rm"
  chmod +x "$MOCK_HOME/.claude/local/rm"

  run run_script
  [ "$status" -eq 0 ]
  [ -L "$MOCK_PROJECT/state/$PICKED/pre-verify" ]
  [ "$(cat "$MOCK_HOME/outside/${DR_DATE}.md")" = "victim" ]
  get_log | grep -q "WARN: Line $PICKED pre-verify copy failed — the pre-verify dir is a symlink that could not be removed"
  get_log | grep -q "VERIFY $PICKED: "
  refute_grep -q "VERIFY_DIFF $PICKED" <<< "$(get_log)"
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
assert list(rec["event_age_days"].values()) == [0], rec  # 短報も新しさを数える (H17、既定 = DR_DATE)
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
assert rec["event_age_days"] is None, rec  # ノートの無い line は新しさを数えない (H17)
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

@test "E2E pending: an article run that adds a pending item warns; a hold run does not (H02)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  mkdir -p "$MOCK_PROJECT/state/$PICKED"
  printf -- '# pending\n\n- **既存の問い**\n  - 状態: pending\n' > "$MOCK_PROJECT/state/$PICKED/pending.md"
  printf -- '- **足された問い**\n### 経過メモ（2026-08-13）\n' > "$MOCK_HOME/.pending_add_$PICKED"

  run run_script
  [ "$status" -eq 0 ]
  local log_content
  log_content=$(get_log)
  echo "$log_content" | grep -q "Line $PICKED pending.md: items 1→3, chars "
  echo "$log_content" | grep -q "WARN: Line $PICKED pending.md の項目が article の run で 2 件増えた"

  # hold の run は保留の問いを足す (WARN なし)
  echo hold > "$MOCK_HOME/.state_$PICKED"
  rm -rf "$MOCK_PROJECT/logs" "$MOCK_PROJECT/state/$PICKED/runs"
  mkdir -p "$MOCK_PROJECT/logs"
  run run_script
  [ "$status" -eq 0 ]
  log_content=$(get_log)
  echo "$log_content" | grep -q "Line $PICKED pending.md: items 3→5, chars "
  refute_grep -q "pending.md の項目が" <<< "$log_content"
}

@test "E2E pending: items added up to the report's dated opportunities do not warn (H02)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  printf -- '- **締切のある機会**\n' > "$MOCK_HOME/.pending_add_$PICKED"
  printf -- '# mock report\n\n本文\n\n## 機会メモ\n\n- **何を**: x\n- **失効日**: 2026-09-01\n\n## ソース\n' > "$MOCK_HOME/.report_$PICKED"

  run run_script
  [ "$status" -eq 0 ]
  local log_content
  log_content=$(get_log)
  echo "$log_content" | grep -q "Line $PICKED pending.md: items 0→1, chars 0→"
  refute_grep -q "pending.md の項目が" <<< "$log_content"
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

@test "E2E vault: an unreadable report dir still ends with the failure notify and a metrics record" {
  # launchd の bash が vault (iCloud Drive) を TCC で拒否される・同期中に entry が消えると find が
  # 非 0 を返す。日次集約の REPORT_COUNT (find | wc | tr) が pipefail で script ごと落ち、
  # 失敗の通知・lint・Pass 3・metrics が全部欠けて「予期せず中断」だけが残っていた
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  mkdir -p "$MOCK_HOME/mock-vault/daily-research"
  chmod 000 "$MOCK_HOME/mock-vault/daily-research"

  run run_script
  chmod 755 "$MOCK_HOME/mock-vault/daily-research"
  [ "$status" -eq 1 ]
  local log_content
  log_content=$(get_log)
  refute_grep -q "unexpected exit" <<< "$log_content"
  echo "$log_content" | grep -q "Failed (E_NO_REPORT"
  echo "$log_content" | grep -q "metrics: appended $DR_DATE (E_NO_REPORT"
  notified "リサーチが失敗しました (lines: $PICKED)"
  assert_metrics << 'PY'
assert rec["final_class"] == "E_NO_REPORT", rec
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
assert list(rec["event_age_days"].values()) == [0], rec  # ノートがあるので数える (H17)
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

@test "E2E window: lines_per_day = 2 runs both lines; each line's history is its own (H01)" {
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
  # past-themes は当該 line だけ (H01) — repo line は同日の先行 line の問いを履歴に持たない
  refute_grep -q "mock question for akc" "$MOCK_HOME/.prompt_authorship"
  grep -q "過去テーマ履歴 (この line の直近 10 件" "$MOCK_HOME/.prompt_authorship"
  refute_grep -q "他 line の直近" "$MOCK_HOME/.prompt_authorship"
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
  # 表から外した行の置き場 (H03-A)。ecosystem line だけが書く
  grep -qF "Edit(//${MOCK_PROJECT#/}/state/eco/watched-archive.md)" "$MOCK_HOME/.allowed_eco"
  refute_grep -qF "Edit(//${MOCK_PROJECT#/}/state/eco/**)" "$MOCK_HOME/.allowed_eco"
  # repo line は watchlist を書かない
  refute_grep -q "watched-sources" "$MOCK_HOME/.allowed_$PICKED"
  refute_grep -q "watched-archive" "$MOCK_HOME/.allowed_$PICKED"
  # watchlist は ecosystem line の書き込み先なので eco の deny には入らない (repo line の deny には入る — 下の厳密一致)
  refute_grep -q "watched-" "$MOCK_HOME/.disallowed_eco"
  grep -qF "Edit(//${MOCK_PROJECT#/}/state/$PICKED/pending.md)" "$MOCK_HOME/.allowed_$PICKED"

  # repo line の実行形は不変
  [ "$(cat "$MOCK_HOME/.cwd_$PICKED")" = "$(cd "$MOCK_HOME/mock-repos/authorship-strategy" && pwd -P)" ]
  [[ "$(cat "$MOCK_HOME/.protocol_$PICKED")" == */prompts/repo-research-protocol.md ]]
  # safe mode・組み込みツールの集合・共通 deny は repo line にも効く (ADR-0019 Decision 2)
  grep -qx -- "--safe-mode" "$MOCK_HOME/.args_$PICKED"
  grep -A1 -x -- '--tools' "$MOCK_HOME/.args_$PICKED" | grep -qx "WebSearch,WebFetch,Read,Glob,Grep,Edit,Write"
  grep -A1 -x -- '--tools' "$MOCK_HOME/.args_eco" | grep -qx "WebSearch,WebFetch,Read,Glob,Grep,Edit,Write"
  [ "$(cat "$MOCK_HOME/.disallowed_$PICKED")" = "Bash,Task,NotebookEdit,Read(//${MOCK_HOME#/}/.claude/**),Read(//${MOCK_HOME#/}/.claude.json),Read(//${MOCK_HOME#/}/.codex/**),Read(//${MOCK_HOME#/}/.config/**),Read(//${MOCK_HOME#/}/.ssh/**),Read(//${MOCK_HOME#/}/.aws/**),Read(//${MOCK_HOME#/}/.gnupg/**),Read(//${MOCK_HOME#/}/.netrc),Read(//${MOCK_HOME#/}/**/logs/episodes/**),Read(//${MOCK_HOME#/}/.config/daily-research/**),Edit(//${MOCK_PROJECT#/}/state/$PICKED/brief.md),Edit(//${MOCK_PROJECT#/}/state/$PICKED/playbook.md),Edit(//${MOCK_PROJECT#/}/past_topics.json),Edit(//${MOCK_PROJECT#/}/state/$PICKED/pre-verify/**),Edit(//${MOCK_PROJECT#/}/state/$PICKED/audit/**),Edit(//${MOCK_PROJECT#/}/state/$PICKED/pre-audit/**),Edit(//${MOCK_PROJECT#/}/state/$PICKED/watched-sources.md),Edit(//${MOCK_PROJECT#/}/state/$PICKED/watched-archive.md)" ]
}

@test "E2E ecosystem: past themes are the line's own plus other lines' titles of the last 7 days (H01)" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  add_ecosystem_daily_line
  cat > "$MOCK_PROJECT/past_topics.json" << EOF
{"topics": [
  {"date": "2026-08-01", "track": "eco", "title": "", "question": "eco old question"},
  {"date": "2026-08-01", "track": "akc", "title": "akc stale title", "question": "akc stale question"},
  {"date": "2026-08-10", "track": "akc", "title": "akc recent title", "question": "akc recent question"}
]}
EOF

  run run_script
  [ "$status" -eq 0 ]

  # ecosystem line: 自 line の問い + 他 line の直近 7 日の題 (同日の先行 line = 輪番の line を含む)
  grep -q "eco old question" "$MOCK_HOME/.prompt_eco"
  grep -q "=== 他 line の直近 7 日の題" "$MOCK_HOME/.prompt_eco"
  grep -qx -- "- 2026-08-10 akc: akc recent title" "$MOCK_HOME/.prompt_eco"
  grep -qx -- "- $DR_DATE $PICKED: mock title for $PICKED" "$MOCK_HOME/.prompt_eco"
  refute_grep -q "akc stale" "$MOCK_HOME/.prompt_eco"
  refute_grep -q "akc recent question" "$MOCK_HOME/.prompt_eco"   # 他 line は題だけ
  # repo line: 自 line の節だけ、他 line 節なし
  refute_grep -q "eco old question" "$MOCK_HOME/.prompt_$PICKED"
  refute_grep -q "akc recent" "$MOCK_HOME/.prompt_$PICKED"
  refute_grep -q "他 line の直近" "$MOCK_HOME/.prompt_$PICKED"
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

@test "E2E: recent repo activity is injected for repo lines only, sanitized" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  add_ecosystem_daily_line
  local repo="$MOCK_HOME/mock-repos/authorship-strategy"
  isolate_git_env
  git -C "$repo" init -q
  git -C "$repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "# feat: mock activity subject"

  run run_script
  [ "$status" -eq 0 ]

  grep -q "^## 直近の repo 活動" "$MOCK_HOME/.prompt_$PICKED"
  grep -qx -- "- feat: mock activity subject" "$MOCK_HOME/.prompt_$PICKED"
  refute_grep -q "直近の repo 活動" "$MOCK_HOME/.prompt_eco"
}

@test "E2E: a repo without git history gets no activity section" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run run_script
  [ "$status" -eq 0 ]

  refute_grep -q "直近の repo 活動" "$MOCK_HOME/.prompt_$PICKED"
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

# === Test: 同時実行ガード (lib/lock.sh の 1 = 実行中、2 = 確かめられない) ===

@test "E2E lock: a lock held by a live daily-research.sh skips the run as another instance" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  # 保持者 = コマンド行が daily-research.sh の生きた process (fd 3 は bats の出力)
  mkdir -p "$MOCK_HOME/holder" "$MOCK_PROJECT/.daily-research.lock"
  printf '#!/bin/bash\nsleep 30\n' > "$MOCK_HOME/holder/daily-research.sh"
  /bin/bash "$MOCK_HOME/holder/daily-research.sh" >/dev/null 2>&1 3>&- &
  local owner=$! i
  for i in $(seq 1 50); do   # fork 直後は exec 前の親のコマンド行が見える
    case "$(ps -ww -p "$owner" -o command= 2>/dev/null)" in *daily-research.sh*) break ;; esac
    sleep 0.1
  done
  echo "$owner" > "$MOCK_PROJECT/.daily-research.lock/pid"

  run run_script
  pkill -P "$owner" 2>/dev/null || true
  kill "$owner" 2>/dev/null || true
  [ "$status" -ne 0 ]
  get_log | grep -qF "ERROR: Another instance is running. Skipping."
  notified "前回のリサーチがまだ実行中です"
  refute_grep -qF "Could not verify the lock" "$MOCK_PROJECT/logs/$DR_DATE.log"
  refute_grep -qF "=== Starting daily research ===" "$MOCK_PROJECT/logs/$DR_DATE.log"
  [ ! -e "$MOCK_HOME/.calls_$PICKED" ]
  [ "$(cat "$MOCK_PROJECT/.daily-research.lock/pid")" = "$owner" ]   # 他者の lock は消さない
}

@test "E2E lock: a lock that cannot be verified skips the run with its own log line and notify" {
  # mutex のファイルを開けない (同名の dir が居座る) = 保持者を確かめられない。実行中と報告せず、run も始めない
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  mkdir "$MOCK_PROJECT/.daily-research.lock.mutex"

  run run_script
  [ "$status" -ne 0 ]
  get_log | grep -qF "ERROR: Could not verify the lock ("
  notified "ロックを確かめられず実行しませんでした"
  refute_grep -qF "Another instance" "$MOCK_PROJECT/logs/$DR_DATE.log"
  refute_grep -qF "前回のリサーチがまだ実行中です" "$MOCK_HOME/.notify_log"
  refute_grep -qF "=== Starting daily research ===" "$MOCK_PROJECT/logs/$DR_DATE.log"
  [ ! -e "$MOCK_HOME/.calls_$PICKED" ]
  [ ! -e "$MOCK_PROJECT/.daily-research.lock" ]
}

# === 呼3: 照合監査 (ADR-0020) ===

AUDIT_SENTENCE="報告書は 2026-10-01 に欧州の 3 か国で公開された。"
AUDIT_FIXED="報告書は 2026-10-01 に欧州の 4 か国で公開された。"

# 監査を有効にし、呼1 が書くノート (.report_<line>) と第 1 段の最終メッセージ (.audit_result) を置く。
# $1 = 候補の置き換え文 (省略時 AUDIT_FIXED)、$2 = 候補の URL (省略時 ノートのソース節の URL)
setup_audit() {
  printf '\n[audit]\nenabled = true\n' >> "$MOCK_PROJECT/config.toml"
  printf -- '---\nkind: article\n---\n\n# mock report for %s\n\n%s\n調査の参加者は 120 人だった。\n\n## ソース\n- [報告書](https://example.com/report)\n' \
    "$PICKED" "$AUDIT_SENTENCE" > "$MOCK_HOME/.report_$PICKED"
  python3 -c '
import json, sys
d = {"claims_checked": 2, "supported": 1, "unverifiable": [], "discrepancies": [{
    "note_sentence": sys.argv[1], "claim": "3 か国", "source_quote": "four countries",
    "url": sys.argv[3], "correct_value": "第1段だけが知る値", "replacement": sys.argv[2],
    "type": "scope", "confidence": "high", "drift": False}]}
print("監査の結果:\n```json\n" + json.dumps(d, ensure_ascii=False) + "\n```")
' "$AUDIT_SENTENCE" "${1-$AUDIT_FIXED}" "${2-https://example.com/report}" > "$MOCK_HOME/.audit_result"
}

audit_note() { echo "$MOCK_HOME/mock-vault/daily-research/${DR_DATE}_${PICKED}_mock-report.md"; }

# 引数ファイル (1 行 1 引数) で flag の直後の値を出す
arg_after() { grep -A1 -xF -- "$2" "$1" | sed -n 2p; }

@test "E2E audit: disabled by default — no audit call, no AUDIT line, no audit_* metrics" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  run run_script
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_HOME/.prompt_audit" ]
  refute_grep -q "AUDIT $PICKED" "$MOCK_PROJECT/logs/$DR_DATE.log"
  refute_grep -q "Audit pass" "$MOCK_PROJECT/logs/$DR_DATE.log"
  assert_metrics << 'PY'
assert not any(k.startswith("audit_") for k in rec["verification"]), rec
PY
}

@test "E2E audit: a candidate both stages confirm is applied; the pre-audit copy and state are kept" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  setup_audit
  run run_script
  [ "$status" -eq 0 ]
  local log_content note pre="$MOCK_PROJECT/state/$PICKED/pre-audit/${DR_DATE}.md"
  log_content=$(get_log)
  note=$(audit_note)
  grep -qF "$AUDIT_FIXED" "$note"
  refute_grep -qF "$AUDIT_SENTENCE" "$note"
  cmp -s "$pre" "$MOCK_HOME/.report_$PICKED"
  echo "$log_content" | grep -q "Audit pass: on (model opus, effort high, ADR-0020)"
  echo "$log_content" | grep -q "AUDIT $PICKED: {\"ran\": true, "
  echo "$log_content" | grep "AUDIT $PICKED:" | grep -q '"applied": 1'
  refute_grep -q "audit pass: " <<< "$log_content"
  python3 -c '
import json, sys
st = json.load(open(sys.argv[1]))
assert [c["status"] for c in st["candidates"]] == ["applied"], st
' "$MOCK_PROJECT/state/$PICKED/audit/${DR_DATE}.json"
  assert_metrics << 'PY'
v = rec["verification"]
assert v["audit_lines"] == 1 and v["audit_ran"] == 1, v
assert v["audit_candidates"] == 1 and v["audit_confirmed"] == 1 and v["audit_applied"] == 1, v
assert v["audit_cost"] == 0.35 and v["audit_turns"] == 12 and v["audit_confirm_turns"] == 4, v
assert rec["total_cost"] >= 0.35, rec
PY
}

@test "E2E audit: both stages run read-only with opus, high effort, WebFetch only, and their turn caps" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  setup_audit
  run run_script
  [ "$status" -eq 0 ]
  local a="$MOCK_HOME/.args_audit" c="$MOCK_HOME/.args_confirm" f
  for f in "$a" "$c"; do
    grep -qx -- "--safe-mode" "$f"
    grep -qx -- "--no-session-persistence" "$f"
    [ "$(arg_after "$f" --tools)" = "WebFetch" ]
    [ "$(arg_after "$f" --allowedTools)" = "WebFetch" ]
    [ "$(arg_after "$f" --permission-mode)" = "default" ]
    [ "$(arg_after "$f" --model)" = "opus" ]
    [ "$(arg_after "$f" --effort)" = "high" ]
    arg_after "$f" --disallowedTools | grep -q ",WebSearch,Read,Glob,Grep,Edit,Write$"
  done
  [ "$(arg_after "$a" --max-turns)" = "40" ]
  [ "$(arg_after "$c" --max-turns)" = "20" ]
  # 第 1 段はノートと根拠ファイルを prompt で受け取る (Read を持たない)
  grep -qF "$AUDIT_SENTENCE" "$MOCK_HOME/.prompt_audit"
  grep -qF "# evidence for $PICKED" "$MOCK_HOME/.prompt_audit"
  # 第 2 段に渡るのは文・置き換え文・ノートの URL・公開日 — 第 1 段の理由と正しい値は渡さない
  grep -qF "$AUDIT_SENTENCE" "$MOCK_HOME/.prompt_confirm"
  grep -qF "$AUDIT_FIXED" "$MOCK_HOME/.prompt_confirm"
  grep -qF "https://example.com/report" "$MOCK_HOME/.prompt_confirm"
  grep -qF "$DR_DATE" "$MOCK_HOME/.prompt_confirm"
  refute_grep -qF "第1段だけが知る値" "$MOCK_HOME/.prompt_confirm"
  # ノート由来の文字列は乱数の印の区切りで挟む (両段)
  grep -qE '^<<<文A [0-9a-f]{16}>>>$' "$MOCK_HOME/.prompt_confirm"
  grep -qE '^<<<ノート [0-9a-f]{16}>>>$' "$MOCK_HOME/.prompt_audit"
}

@test "E2E audit: a candidate whose URL is not in the note is skipped without a stage 2 call" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  setup_audit "$AUDIT_FIXED" "https://evil.example/report"
  run run_script
  [ "$status" -eq 0 ]
  cmp -s "$(audit_note)" "$MOCK_HOME/.report_$PICKED"
  [ ! -e "$MOCK_HOME/.prompt_confirm" ]
  python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))["candidates"][0]
assert (c["status"], c["reason"]) == ("skipped", "url_not_in_note"), c
' "$MOCK_PROJECT/state/$PICKED/audit/${DR_DATE}.json"
}

@test "E2E audit: a fix stage 2 does not accept is rejected with a WARN" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  setup_audit
  echo "contradicts" > "$MOCK_HOME/.confirm_rv"
  run run_script
  [ "$status" -eq 0 ]
  cmp -s "$(audit_note)" "$MOCK_HOME/.report_$PICKED"
  get_log | grep -q "WARN: Line $PICKED audit pass: 監査で確定した候補 D1 を適用しなかった (fix_unconfirmed)"
}

@test "E2E audit: stage 1 failure is fail-open — the note stays as after call 2 and the run succeeds" {
  echo "audit-fail" > "$MOCK_HOME/.mock_scenario"
  setup_audit
  run run_script
  [ "$status" -eq 0 ]
  local log_content
  log_content=$(get_log)
  cmp -s "$(audit_note)" "$MOCK_HOME/.report_$PICKED"
  echo "$log_content" | grep -q "WARN: Line $PICKED audit stage 1 did not run or failed ("
  echo "$log_content" | grep -q "AUDIT $PICKED: {\"ran\": false, "
  [ ! -e "$MOCK_HOME/.prompt_confirm" ]
  [ ! -e "$MOCK_PROJECT/state/$PICKED/pre-audit/${DR_DATE}.md" ]
  assert_metrics << 'PY'
assert rec["final_class"] == "OK", rec
v = rec["verification"]
assert v["audit_lines"] == 1 and v["audit_ran"] == 0 and v["audit_applied"] == 0, v
PY
}

@test "E2E audit: a candidate stage 2 finds consistent is not applied" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  setup_audit
  echo "consistent" > "$MOCK_HOME/.confirm_verdict"
  run run_script
  [ "$status" -eq 0 ]
  cmp -s "$(audit_note)" "$MOCK_HOME/.report_$PICKED"
  get_log | grep "AUDIT $PICKED:" | grep -q '"candidates": 1, "confirmed": 0, "applied": 0'
  python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))["candidates"][0]
assert (c["status"], c["reason"]) == ("not_confirmed", "consistent"), c
' "$MOCK_PROJECT/state/$PICKED/audit/${DR_DATE}.json"
}

@test "E2E audit: a confirmed candidate without a usable replacement is rejected with a WARN" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  setup_audit ""
  run run_script
  [ "$status" -eq 0 ]
  cmp -s "$(audit_note)" "$MOCK_HOME/.report_$PICKED"
  get_log | grep -q "WARN: Line $PICKED audit pass: 監査で確定した候補 D1 を適用しなかった (empty)"
  get_log | grep "AUDIT $PICKED:" | grep -q '"confirmed": 1, "applied": 0, "rejected": 1'
}

@test "E2E audit: a brief note is not audited" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  setup_audit
  echo brief > "$MOCK_HOME/.state_$PICKED"
  run run_script
  [ "$status" -eq 0 ]
  get_log | grep -q "Line $PICKED audit pass skipped (kind: brief, only article is audited)"
  [ ! -e "$MOCK_HOME/.prompt_audit" ]
}

@test "E2E audit: a stale audit state from an earlier invocation is removed before stage 1" {
  # audit-stage1 だけを失敗させる python3 の shim (今回の状態を書かせない。lib/env.sh は ~/.local/bin を PATH の
  # 先頭に置く)。SH の rm が効かなければ、前回の confirmed の候補がこの run で当たってノートが変わる
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  setup_audit
  local real_py
  real_py=$(command -v python3)
  mkdir -p "$MOCK_HOME/.local/bin" "$MOCK_PROJECT/state/$PICKED/audit"
  printf '#!/bin/bash\nif [ "$2" = "audit-stage1" ]; then cat > /dev/null; exit 1; fi\nexec "%s" "$@"\n' \
    "$real_py" > "$MOCK_HOME/.local/bin/python3"
  chmod +x "$MOCK_HOME/.local/bin/python3"
  python3 -c '
import json, sys
c = {"id": "D1", "status": "confirmed", "note_sentence": sys.argv[1], "replacement": sys.argv[2],
     "confirm": {"verdict": "contradicts", "replacement_verdict": "consistent",
                 "parts": [{"wrong": "3 か国", "fixed": "4 か国"}]}}
print(json.dumps({"version": 1, "date": "", "ran": True, "stage1": {}, "confirm": {}, "candidates": [c]},
                 ensure_ascii=False))
' "$AUDIT_SENTENCE" "$AUDIT_FIXED" > "$MOCK_PROJECT/state/$PICKED/audit/${DR_DATE}.json"
  run run_script
  [ "$status" -eq 0 ]
  cmp -s "$(audit_note)" "$MOCK_HOME/.report_$PICKED"
  get_log | grep "AUDIT $PICKED:" | grep -q '"ran": false, "reason": "no_state"'
}

@test "E2E audit: a directory on the audit state path skips the audit; the run still succeeds" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  setup_audit
  mkdir -p "$MOCK_PROJECT/state/$PICKED/audit/${DR_DATE}.json/x"
  run run_script
  [ "$status" -eq 0 ]
  cmp -s "$(audit_note)" "$MOCK_HOME/.report_$PICKED"
  [ ! -e "$MOCK_HOME/.prompt_audit" ]
  get_log | grep -q "WARN: Line $PICKED audit pass skipped — the audit state path could not be cleared"
  get_log | grep "AUDIT $PICKED:" | grep -q '"ran": false, "reason": "E_STATE"'
  get_log | grep -q "=== Completed successfully ==="
}

@test "E2E audit: the script-only state dirs (pre-verify, audit, pre-audit) are denied to calls 1 and 2" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"
  run run_script
  [ "$status" -eq 0 ]
  local d
  for d in pre-verify audit pre-audit; do
    grep -qF "Edit(//${MOCK_PROJECT#/}/state/$PICKED/$d/**)" "$MOCK_HOME/.disallowed_$PICKED"
    grep -qF "Edit(//${MOCK_PROJECT#/}/state/$PICKED/$d/**)" "$MOCK_HOME/.disallowed_clarity"
  done
}
