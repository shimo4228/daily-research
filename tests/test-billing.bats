#!/usr/bin/env bats
# API 課金 ([billing]、lib/billing.sh) のテスト: classify_exit の課金系の分類と、mock claude を使った
# orchestrator / check-auth.sh の E2E (key の受け渡し・呼び出しごとの上限・支出台帳・月/日の上限・
# 429 とクレジット切れでの停止)。
# mock は quiet の receipt だけを書く — ノート・呼2 の経路は test-e2e-mock.bats が持つ。

REAL_PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB_DIR="$REAL_PROJECT_DIR/scripts/lib"
DR_PY="$LIB_DIR/dr_pipeline.py"
FAKE_KEY="test-key-e2e-0000"

load test_helper

setup() {
  MOCK_HOME="$(mktemp -d)"
  P="$MOCK_HOME/daily-research"
  mkdir -p "$P/scripts" "$P/prompts" "$P/templates" "$P/logs" "$MOCK_HOME/.claude/local" \
    "$MOCK_HOME/repos/akc" "$MOCK_HOME/repos/authorship" "$MOCK_HOME/.config/dr"
  cp "$REAL_PROJECT_DIR/scripts/daily-research.sh" "$REAL_PROJECT_DIR/scripts/check-auth.sh" "$P/scripts/"
  cp -R "$REAL_PROJECT_DIR/scripts/lib" "$P/scripts/"
  cp "$REAL_PROJECT_DIR/prompts/repo-research-protocol.md" "$P/prompts/"
  cp "$REAL_PROJECT_DIR/tests/fixtures/verification-protocol.stub.md" "$P/prompts/verification-protocol.md"
  cp "$REAL_PROJECT_DIR/templates/report-template.md" "$P/templates/"
  echo '{"topics": []}' > "$P/past_topics.json"
  # 変数名と値を分けて書く (secret scan の KEY=値 パターンに当てないため)
  printf 'OTHER=1\nexport %s="%s"\n' ANTHROPIC_API_KEY "$FAKE_KEY" > "$MOCK_HOME/.config/dr/env"
  BILLING_BLOCK="[billing]
mode = \"api\"
env_file = \"$MOCK_HOME/.config/dr/env\"
monthly_cap_usd = 190
daily_cap_usd = 15
call1_max_usd = 4
call2_max_usd = 1.5"
  write_config "$BILLING_BLOCK"
  export DR_DATE="2026-11-02"
  echo "ok" > "$MOCK_HOME/.scenario"
  echo "2.0" > "$MOCK_HOME/.cost"
  create_mocks
}

teardown() {
  rm -rf "$MOCK_HOME"
}

write_config() {
  cat > "$P/config.toml" <<EOF
[general]
vault_path = "$MOCK_HOME/vault"
output_dir = "daily-research"
lines_per_day = 2

$1

[tracks.akc]
name = "AKC"
focus = "akc focus"

[[tracks.akc.repos]]
key = "akc"
target_repo = "$MOCK_HOME/repos/akc"

[tracks.authorship]
name = "Authorship"
focus = "authorship focus"

[[tracks.authorship.repos]]
key = "authorship"
target_repo = "$MOCK_HOME/repos/authorship"
EOF
}

create_mocks() {
  cat > "$MOCK_HOME/.claude/local/claude" <<'MOCK'
#!/bin/bash
H="$(dirname "$(dirname "$(dirname "$0")")")"
SC=$(cat "$H/.scenario")
COST=$(cat "$H/.cost")
[[ "$1" == "--version" ]] && { echo "mock"; exit 0; }
PROTOCOL=""; PROMPT=""; BUDGET="none"; PREV=""
for a in "$@"; do
  case "$PREV" in
    --append-system-prompt-file) PROTOCOL="$a" ;;
    -p) PROMPT="$a" ;;
    --max-budget-usd) BUDGET="$a" ;;
  esac
  PREV="$a"
done
KIND=probe
[ -n "$PROTOCOL" ] && KIND=$(basename "$PROTOCOL" .md)
echo "CALL kind=$KIND key=${ANTHROPIC_API_KEY:-unset} budget=$BUDGET" >> "$H/.calls"
if [ "$KIND" = "probe" ]; then
  if [ "$SC" = "probe-401" ]; then
    echo '{"type":"result","is_error":true,"api_error_status":401,"total_cost_usd":0,"result":"Invalid API key"}'
    exit 1
  fi
  echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01}'
  exit 0
fi
# seam .break_ledger_at: この種類の呼び出しの前に台帳を dir に替える (その呼び出しの費用の追記から失敗する)
if [ "$(cat "$H/.break_ledger_at" 2>/dev/null)" = "$KIND" ]; then
  rm -f "$H/daily-research/state/api-spend.jsonl"; mkdir -p "$H/daily-research/state/api-spend.jsonl"
fi
R=$(printf '%s' "$PROMPT" | grep -oE '/[^ ]*/state/[A-Za-z0-9_-]+/runs/[0-9]{4}-[0-9]{2}-[0-9]{2}\.json' | head -1)
L=$(basename "$(dirname "$(dirname "$R")")"); D=$(basename "$R" .json)
case "$SC" in
  timeout)
    exit 124 ;;
  note-audit)
    # 呼1 はノートと article の receipt を書く。呼2 は何も変えず、呼3 の第 1 段は候補 1 件、第 2 段は確定を返す。
    # 第 1 段の費用は seam .audit_cost (既定 0.3)
    case "$KIND" in
      verification-protocol)
        echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1,"num_turns":2}'
        exit 0 ;;
      audit-protocol)
        python3 -c 'import json, sys; d = {"claims_checked": 1, "supported": 0, "unverifiable": [], "discrepancies": [{"note_sentence": "報告書は 3 か国で公開された。", "url": "https://example.com/r", "replacement": "報告書は 4 か国で公開された。", "confidence": "high"}]}; print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "total_cost_usd": float(sys.argv[1]), "num_turns": 9, "result": json.dumps(d)}))' \
          "$(cat "$H/.audit_cost" 2>/dev/null || echo 0.3)"
        exit 0 ;;
      audit-confirm-protocol)
        echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.05,"num_turns":3,"result":"{\"verdict\": \"contradicts\", \"replacement_verdict\": \"consistent\", \"parts\": [{\"wrong\": \"3 か国\", \"fixed\": \"4 か国\"}]}"}'
        exit 0 ;;
    esac
    V=$(printf '%s' "$PROMPT" | grep -oE '1\. レポート: [^ ]+' | head -1 | sed 's/^1\. レポート: //')
    VD=$(dirname "$V"); mkdir -p "$VD"
    printf -- '---\nkind: article\n---\n\n# t\n\n報告書は 3 か国で公開された。\n\n## ソース\n- [r](https://example.com/r)\n' > "$VD/${D}_${L}_note.md"
    printf '{"date":"%s","line":"%s","status":"article","report":"%s_%s_note.md","question":"q","reason":"r","reason_code":"no_new_evidence"}' "$D" "$L" "$D" "$L" > "$R"
    echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"total_cost_usd\":$COST,\"num_turns\":3}"
    exit 0 ;;
  note-then-429)
    # ノートと article の receipt を書いた後に 429 で落ちる (呼2 の対象が残る形)
    V=$(printf '%s' "$PROMPT" | grep -oE '1\. レポート: [^ ]+' | head -1 | sed 's/^1\. レポート: //')
    VD=$(dirname "$V"); mkdir -p "$VD"
    printf -- '---\nkind: article\n---\nbody\n' > "$VD/${D}_${L}_note.md"
    printf '{"date":"%s","line":"%s","status":"article","report":"%s_%s_note.md","question":"q","reason":"r","reason_code":"no_new_evidence"}' "$D" "$L" "$D" "$L" > "$R"
    echo '{"type":"result","is_error":true,"api_error_status":429,"total_cost_usd":1.0,"result":"rate_limit_error"}'
    exit 1 ;;
  call2-429)
    # 呼1 はノートと article の receipt を書いて成功し、呼2 が 429 で落ちる
    if [ "$KIND" = "verification-protocol" ]; then
      echo '{"type":"result","is_error":true,"api_error_status":429,"total_cost_usd":0.2,"result":"rate_limit_error"}'
      exit 1
    fi
    V=$(printf '%s' "$PROMPT" | grep -oE '1\. レポート: [^ ]+' | head -1 | sed 's/^1\. レポート: //')
    VD=$(dirname "$V"); mkdir -p "$VD"
    printf -- '---\nkind: article\n---\nbody\n' > "$VD/${D}_${L}_note.md"
    printf '{"date":"%s","line":"%s","status":"article","report":"%s_%s_note.md","question":"q","reason":"r","reason_code":"no_new_evidence"}' "$D" "$L" "$D" "$L" > "$R"
    echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":2.0,"num_turns":3}'
    exit 0 ;;
  rate-limit)
    echo '{"type":"result","is_error":true,"api_error_status":429,"total_cost_usd":0.3,"result":"rate_limit_error"}'
    exit 1 ;;
  credit)
    echo '{"type":"result","is_error":true,"api_error_status":400,"total_cost_usd":0,"result":"Your credit balance is too low to access the Anthropic API."}'
    exit 1 ;;
  budget)
    echo '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":4.1,"errors":["Reached maximum budget ($4)"]}'
    exit 1 ;;
  ledger-breaks)
    # 台帳をディレクトリに替えてから quiet で成功する (この呼び出しの費用の追記から失敗する)
    rm -f "$H/daily-research/state/api-spend.jsonl"; mkdir -p "$H/daily-research/state/api-spend.jsonl" ;;
esac
printf '{"date":"%s","line":"%s","status":"quiet","report":null,"question":"q","reason":"r","reason_code":"no_new_evidence"}' "$D" "$L" > "$R"
echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"total_cost_usd\":$COST,\"num_turns\":3,\"usage\":{\"server_tool_use\":{\"web_search_requests\":2}}}"
exit 0
MOCK
  chmod +x "$MOCK_HOME/.claude/local/claude"
  cat > "$MOCK_HOME/.claude/local/osascript" <<'STUB'
#!/bin/bash
H="$(dirname "$(dirname "$(dirname "$0")")")"
echo "$*" >> "$H/.notify_log"
STUB
  chmod +x "$MOCK_HOME/.claude/local/osascript"
}

run_script() {
  printf -v ANTHROPIC_API_KEY '%s' "inherited-should-not-be-used"
  export ANTHROPIC_API_KEY
  HOME="$MOCK_HOME" bash "$P/scripts/daily-research.sh" 2>&1
}

log_file() { echo "$P/logs/$DR_DATE.log"; }
ledger() { echo "$P/state/api-spend.jsonl"; }
calls_of() { grep -c "kind=$1" "$MOCK_HOME/.calls" || true; }

# === classify_exit (lib/claude.sh) の課金系 ===

@test "classify_exit (api mode): 403 -> E_AUTH, 429 / credit -> E_BILLING, max budget -> E_BUDGET" {
  source "$LIB_DIR/claude.sh"
  BILLING_MODE=api
  [ "$(classify_exit 1 '{"is_error":true,"api_error_status":403}')" = "E_AUTH" ]
  [ "$(classify_exit 1 '{"is_error":true,"api_error_status":429}')" = "E_BILLING" ]
  [ "$(classify_exit 1 '{"is_error":true,"api_error_status":400,"result":"Your credit balance is too low"}')" = "E_BILLING" ]
  [ "$(classify_exit 1 '{"is_error":true,"subtype":"error_max_budget_usd"}')" = "E_BUDGET" ]
  [ "$(classify_exit 1 '{"is_error":true,"api_error_status":500}')" = "E_FATAL" ]
  [ "$(classify_exit 0 '{"is_error":false}')" = "OK" ]
}

@test "classify_exit (subscription mode): 403 and 429 keep the old E_FATAL (one retry)" {
  source "$LIB_DIR/claude.sh"
  BILLING_MODE=subscription
  [ "$(classify_exit 1 '{"is_error":true,"api_error_status":403}')" = "E_FATAL" ]
  [ "$(classify_exit 1 '{"is_error":true,"api_error_status":429}')" = "E_FATAL" ]
  [ "$(classify_exit 1 '{"is_error":true,"api_error_status":401}')" = "E_AUTH" ]
}

@test "classify_exit: real rejected-API-key result (claude 2.1.312) -> E_AUTH" {
  source "$LIB_DIR/claude.sh"
  [ "$(classify_exit 1 "$(cat "$REAL_PROJECT_DIR/tests/fixtures/result-401-api-key.json")")" = "E_AUTH" ]
}

# === billing_gate (lib/billing.sh) の単体 ===

@test "billing_gate: a mktemp failure is logged as a gate failure and returns 2, not the cap's 1" {
  # mktemp が失敗する (disk full・不正な TMPDIR) と billing_gate は無言で 1 を返し、呼ぶ側の
  # 「上限で止めた」ログだけが残っていた。上限を確かめられない停止は 2 で返し、呼ぶ側が文言を分ける
  PROJECT_DIR="$P"; DATE="$DR_DATE"
  source "$LIB_DIR/billing.sh"
  BILLING_MODE=api; BILLING_MONTHLY_CAP=190; BILLING_DAILY_CAP=15; BILLING_RESERVE=5.5
  mktemp() { return 1; }
  run billing_gate
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: "*"cannot check the caps"* ]]
}

@test "billing_gate: spend-gate's rc 1 without a stop line (an uncaught exception) is a gate failure (2)" {
  # rc 1 は spend-gate の「上限で止める」(出力 stop<TAB>month<TAB>day) だが、python の未捕捉例外も rc 1 になる。
  # 出力が stop で始まらない rc 1 を上限と読むと、上限に達していない日に「上限に達した」と通知する
  PROJECT_DIR="$P"; DATE="$DR_DATE"
  source "$LIB_DIR/billing.sh"
  BILLING_MODE=api; BILLING_MONTHLY_CAP=190; BILLING_DAILY_CAP=15; BILLING_RESERVE=5.5
  DR_PY="$MOCK_HOME/raises.py"
  printf 'raise RuntimeError("boom")\n' > "$DR_PY"
  run billing_gate
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: API spend gate failed (rc 1): "*"RuntimeError: boom"*"cannot check the caps"* ]]
  # 上限で止める rc 1 はそのまま 1
  DR_PY="$LIB_DIR/dr_pipeline.py"
  mkdir -p "$P/state"
  echo '{"date":"2026-11-01","line":"akc","call":"call1","cost_usd":186}' > "$(ledger)"
  run billing_gate
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# === orchestrator E2E ===

@test "api mode: key from env_file reaches claude, per-call cap is passed, spend is logged" {
  run run_script
  [ "$status" -eq 0 ]
  # 親の環境の key ではなく env_file の key が届く
  [ "$(grep -c "key=$FAKE_KEY" "$MOCK_HOME/.calls")" -eq 3 ]
  [ "$(grep -c "key=inherited" "$MOCK_HOME/.calls" || true)" -eq 0 ]
  [ "$(grep -c "kind=repo-research-protocol key=$FAKE_KEY budget=4" "$MOCK_HOME/.calls")" -eq 2 ]
  # 台帳: probe 1 + 呼1 2 行
  [ "$(wc -l < "$(ledger)" | tr -d ' ')" -eq 3 ]
  [ "$(stat -f '%Lp' "$(ledger)")" = "600" ]
  grep -q 'Billing: api' "$(log_file)"
  grep -q 'API spend: today \$4.01 / \$15, month \$4.01 / \$190' "$(log_file)"
  # key の値はログに出ない
  [ "$(grep -c "$FAKE_KEY" "$(log_file)" || true)" -eq 0 ]
}

@test "subscription mode: inherited ANTHROPIC_API_KEY is dropped, no cap flag, no ledger" {
  write_config ""
  run run_script
  [ "$status" -eq 0 ]
  [ "$(grep -c "key=unset budget=none" "$MOCK_HOME/.calls")" -eq 3 ]
  [ ! -e "$(ledger)" ]
  grep -q 'Billing: subscription' "$(log_file)"
}

@test "monthly cap already reached: no line starts, E_BUDGET, notify" {
  mkdir -p "$P/state"
  echo '{"date":"2026-11-01","line":"akc","call":"call1","cost_usd":186}' > "$(ledger)"
  run run_script
  [ "$status" -eq 1 ]
  [ "$(calls_of repo-research-protocol)" -eq 0 ]
  grep -q 'Lines not started: ' "$(log_file)"
  grep -q 'API spend gate stopped the run' "$(log_file)"
  grep -qF 'API 支出の上限に達したため、' "$MOCK_HOME/.notify_log"
  grep -qF 'API 支出の上限のため、今朝のリサーチは実行していません' "$MOCK_HOME/.notify_log"
  refute_grep -qF '確かめられ' "$MOCK_HOME/.notify_log"
  grep -q '"final_class": "E_BUDGET"' "$P/metrics.jsonl"
}

# 上限を確かめられずに止めた日の通知 (billing_gate rc 2)。上限と言わず、理由の在りかを log と名指す。
# 分類は上限の日と同じ E_BUDGET (1 line も始めなかった日)
assert_unchecked_stop_notified() {
  grep -qF 'WARN: API spend gate could not check the caps' "$(log_file)"
  refute_grep -qF 'API spend gate stopped the run' "$(log_file)"
  grep -qF 'API 支出を確かめられなかったため、' "$MOCK_HOME/.notify_log"
  grep -qF '今朝のリサーチは実行していません' "$MOCK_HOME/.notify_log"
  refute_grep -qF '上限に達した' "$MOCK_HOME/.notify_log"
  refute_grep -qF '上限のため' "$MOCK_HOME/.notify_log"
  grep -q '"final_class": "E_BUDGET"' "$P/metrics.jsonl"
}

@test "daily cap: the second line is not started once the day's remainder is below one line's reserve" {
  # 日の上限 8、1 line の予約 5.5。1 本目の後の今日の支出は probe 0.01 + 3.0 = 3.01、
  # 残り 4.99 < 5.5 なので 2 本目は始めない
  echo "3.0" > "$MOCK_HOME/.cost"
  sed -i '' 's/daily_cap_usd = 15/daily_cap_usd = 8/' "$P/config.toml"
  run run_script
  [ "$status" -eq 0 ]
  [ "$(calls_of repo-research-protocol)" -eq 1 ]
  grep -q 'API spend gate stopped the run' "$(log_file)"
  grep -q '未実行' "$MOCK_HOME/.notify_log"
  grep -q 'API 支出の上限に達したため、[a-z]* を止めました' "$MOCK_HOME/.notify_log"
}

@test "429 on the first line: no retry, remaining line not started, billing notify" {
  echo "rate-limit" > "$MOCK_HOME/.scenario"
  run run_script
  [ "$status" -eq 1 ]
  [ "$(calls_of repo-research-protocol)" -eq 1 ]
  grep -q 'billing/rate-limit error' "$(log_file)"
  grep -q 'Lines not started: ' "$(log_file)"
  grep -q '課金エラー' "$MOCK_HOME/.notify_log"
}

@test "credit balance too low: treated like 429 (no retry, stop)" {
  echo "credit" > "$MOCK_HOME/.scenario"
  run run_script
  [ "$status" -eq 1 ]
  [ "$(calls_of repo-research-protocol)" -eq 1 ]
  grep -q 'billing/rate-limit error' "$(log_file)"
}

@test "per-call cap hit: that line is not retried, the next line still runs" {
  echo "budget" > "$MOCK_HOME/.scenario"
  run run_script
  [ "$status" -eq 1 ]   # receipt の無い line はゲートで失敗
  [ "$(calls_of repo-research-protocol)" -eq 2 ]   # 2 line × 1 回 (再試行なし)
  [ "$(grep -c 'reached --max-budget-usd' "$(log_file)")" -eq 2 ]
}

@test "api mode with no key in env_file: stops before any claude call" {
  echo "OTHER=1" > "$MOCK_HOME/.config/dr/env"
  run run_script
  [ "$status" -eq 1 ]
  [ ! -e "$MOCK_HOME/.calls" ]
  grep -q 'billing setup failed' "$(log_file)"
}

@test "api mode probe rejected: exit 1 with an API-specific notify" {
  echo "probe-401" > "$MOCK_HOME/.scenario"
  run run_script
  [ "$status" -eq 1 ]
  [ "$(calls_of repo-research-protocol)" -eq 0 ]
  grep -q 'Auth probe failed (api)' "$(log_file)"
  grep -q 'Claude API の認証に失敗' "$MOCK_HOME/.notify_log"
}

@test "429 after a note was written: call 2 does not run" {
  echo "note-then-429" > "$MOCK_HOME/.scenario"
  run run_script
  [ "$(calls_of repo-research-protocol)" -eq 1 ]
  [ "$(calls_of verification-protocol)" -eq 0 ]
  grep -q 'billing/rate-limit error' "$(log_file)"
  grep -q 'clarity pass skipped after an auth/billing error' "$(log_file)"
  # ゲートに落ちた line は無いが、2 本目は始めていない — 「全 line 成功」ではない (ADR-0011)
  [ "$status" -eq 1 ]
  grep -q '"final_class": "E_PARTIAL"' "$P/metrics.jsonl"
}

@test "429 in call 2: the remaining line is not started and the day is E_PARTIAL, not a success" {
  # 呼2 の課金・認証の中断は残 line を止めるが、止めた line はゲートを通らないので FAILED_LINES が
  # 空のまま残り、最終が OK / exit 0 / 「完成しました」になっていた
  echo "call2-429" > "$MOCK_HOME/.scenario"
  run run_script
  [ "$status" -eq 1 ]
  [ "$(calls_of repo-research-protocol)" -eq 1 ]
  [ "$(calls_of verification-protocol)" -eq 1 ]
  grep -q 'clarity pass hit a billing/rate-limit error' "$(log_file)"
  grep -q 'Lines not started: ' "$(log_file)"
  grep -q 'Failed (E_PARTIAL' "$(log_file)"
  if grep -q 'Completed successfully' "$(log_file)"; then false; fi
  grep -q '"final_class": "E_PARTIAL"' "$P/metrics.jsonl"
  grep -q 'リサーチが一部失敗しました (今朝: [a-z]* / 未検証: [a-z]* / 未実行: [a-z]*)' "$MOCK_HOME/.notify_log"
}

# === 呼3 (照合監査、ADR-0020) の上限と台帳 ===

@test "audit enabled (api mode): both audit stages get their own per-call cap and ledger rows" {
  echo "note-audit" > "$MOCK_HOME/.scenario"
  printf '\n[audit]\nenabled = true\n' >> "$P/config.toml"
  run run_script
  [ "$status" -eq 0 ]
  [ "$(grep -c "kind=audit-protocol key=$FAKE_KEY budget=1$" "$MOCK_HOME/.calls")" -eq 2 ]
  [ "$(grep -c "kind=audit-confirm-protocol key=$FAKE_KEY budget=0.25$" "$MOCK_HOME/.calls")" -eq 2 ]
  # 台帳: probe 1 + 2 line × (呼1・呼2・呼3 の 2 段)
  [ "$(wc -l < "$(ledger)" | tr -d ' ')" -eq 9 ]
  [ "$(grep -c '"call": "audit"' "$(ledger)")" -eq 2 ]
  [ "$(grep -c '"call": "audit_confirm"' "$(ledger)")" -eq 2 ]
  grep -q 'audit \$1 / audit_confirm \$0.25; line reserve \$7.75' "$(log_file)"
  # 2 line × 0.1 + 2.0 + 0.3 + 0.05 と probe 0.01
  grep -q 'API spend: today \$4.91 / \$15' "$(log_file)"
  grep -q '"applied": 1' "$(log_file)"
  grep -q '"audit_applied": 2' "$P/metrics.jsonl"
}

@test "audit enabled: the day's reserve per line includes the audit, so the second line is not started" {
  # 日の上限 8。1 本目の後の今日の支出は probe 0.01 + 2.0 + 0.1 + 0.3 + 0.05 = 2.46、残り 5.54。
  # 監査なしの予約 5.5 なら 2 本目は始まるが、監査ありの予約 7.75 には届かない
  echo "note-audit" > "$MOCK_HOME/.scenario"
  sed -i '' 's/daily_cap_usd = 15/daily_cap_usd = 8/' "$P/config.toml"
  printf '\n[audit]\nenabled = true\n' >> "$P/config.toml"
  run run_script
  [ "$status" -eq 0 ]
  [ "$(calls_of repo-research-protocol)" -eq 1 ]
  [ "$(calls_of audit-protocol)" -eq 1 ]
  grep -q 'API spend gate stopped the run' "$(log_file)"
}

@test "audit enabled with a daily cap below the line reserve: the run stops at config load" {
  sed -i '' 's/daily_cap_usd = 15/daily_cap_usd = 6/' "$P/config.toml"
  printf '\n[audit]\nenabled = true\n' >> "$P/config.toml"
  run run_script
  [ "$status" -ne 0 ]
  [ ! -e "$MOCK_HOME/.calls" ]   # probe より前に止まる
  grep -q 'audit_confirm_max_usd' "$(log_file)"
}

@test "audit stage 1 gate at a cap (rc 1): stage 1 does not run and the log names the cap" {
  # 日の上限 15。1 本目の後の今日の支出は probe 0.01 + 呼1 13 + 呼2 0.1 = 13.11、残り 1.89 < 監査の予約 2.25
  echo "note-audit" > "$MOCK_HOME/.scenario"
  echo "13" > "$MOCK_HOME/.cost"
  printf '\n[audit]\nenabled = true\n' >> "$P/config.toml"
  run run_script
  [ "$(calls_of repo-research-protocol)" -eq 1 ]
  [ "$(calls_of audit-protocol)" -eq 0 ]
  grep -qF 'audit pass skipped — API spend cap (month $13.11, day $13.11, need $2.25)' "$(log_file)"
  refute_grep -qF 'audit pass skipped — the API spend gate could not check the caps' "$(log_file)"
  grep '] AUDIT [a-z]*: ' "$(log_file)" | grep -q '"ran": false, "reason": "E_BUDGET_GATE"'
}

@test "audit stage 1 gate cannot check the caps (rc 2): stage 1 does not run and the log does not call it a cap" {
  # 呼2 の前に台帳を dir に替える — 呼2 の費用の追記が失敗し、以後の gate は上限を確かめられない
  echo "note-audit" > "$MOCK_HOME/.scenario"
  echo "verification-protocol" > "$MOCK_HOME/.break_ledger_at"
  printf '\n[audit]\nenabled = true\n' >> "$P/config.toml"
  run run_script
  [ "$(calls_of verification-protocol)" -eq 1 ]
  [ "$(calls_of audit-protocol)" -eq 0 ]
  grep -qF 'audit pass skipped — the API spend gate could not check the caps' "$(log_file)"
  refute_grep -qF 'audit pass skipped — API spend cap' "$(log_file)"
  grep '] AUDIT [a-z]*: ' "$(log_file)" | grep -q '"ran": false, "reason": "E_BUDGET_GATE"'
}

@test "audit stage 2 gate at a cap (rc 1): the candidate is not sent to stage 2 and nothing is applied" {
  # 1 本目: probe 0.01 + 呼1 2.0 + 呼2 0.1 = 2.11 で第 1 段は回る (残り 12.89 >= 2.25)。第 1 段 12.7 で 14.81、
  # 残り 0.19 < 第 2 段の 1 回分 0.25
  echo "note-audit" > "$MOCK_HOME/.scenario"
  echo "12.7" > "$MOCK_HOME/.audit_cost"
  printf '\n[audit]\nenabled = true\n' >> "$P/config.toml"
  run run_script
  [ "$(calls_of audit-protocol)" -eq 1 ]
  [ "$(calls_of audit-confirm-protocol)" -eq 0 ]
  grep -qF 'audit stage 2 stopped — API spend cap (day $14.81)' "$(log_file)"
  refute_grep -qF 'audit stage 2 stopped — the API spend gate could not check the caps' "$(log_file)"
  grep '] AUDIT [a-z]*: ' "$(log_file)" | grep -q '"candidates": 1, "confirmed": 0, "applied": 0'
}

@test "audit stage 2 gate cannot check the caps (rc 2): the candidate is not sent and the log does not call it a cap" {
  # 第 1 段の前に台帳を dir に替える — 第 1 段の費用の追記が失敗し、第 2 段の前の gate は上限を確かめられない
  echo "note-audit" > "$MOCK_HOME/.scenario"
  echo "audit-protocol" > "$MOCK_HOME/.break_ledger_at"
  printf '\n[audit]\nenabled = true\n' >> "$P/config.toml"
  run run_script
  [ "$(calls_of audit-protocol)" -eq 1 ]
  [ "$(calls_of audit-confirm-protocol)" -eq 0 ]
  grep -qF 'audit stage 2 stopped — the API spend gate could not check the caps' "$(log_file)"
  refute_grep -qF 'audit stage 2 stopped — API spend cap' "$(log_file)"
  grep '] AUDIT [a-z]*: ' "$(log_file)" | grep -q '"candidates": 1, "confirmed": 0, "applied": 0'
}

@test "timed-out call (no result JSON): the call's cap is recorded as an estimate, not \$0" {
  echo "timeout" > "$MOCK_HOME/.scenario"
  run run_script
  # 1 本目は初回 + 再試行で 8 ドル (見積もり)。2 本目は初回の後、日の残り 15 - 12.01 < 5.5 なので
  # 再試行しない → 見積もり 3 行。0 円で記録していたら 4 回とも通っていた
  [ "$(grep -c '"call": "call1", "cost_usd": 4.0, "estimated": true' "$(ledger)")" -eq 3 ]
  [ "$(calls_of repo-research-protocol)" -eq 3 ]
}

@test "the retry is not started when the timed-out first attempt used up the day's room" {
  echo "timeout" > "$MOCK_HOME/.scenario"
  sed -i '' 's/daily_cap_usd = 15/daily_cap_usd = 9/' "$P/config.toml"   # 9 - 0.01 - 4 = 4.99 < 5.5
  run run_script
  [ "$(calls_of repo-research-protocol)" -eq 1 ]
  grep -q 'retry skipped — API spend cap' "$(log_file)"
}

@test "unreadable ledger line: the gate stops instead of under-counting" {
  mkdir -p "$P/state"
  echo '{"date":"2026-11-01","cost_usd":1}' > "$(ledger)"
  echo 'garbage{' >> "$(ledger)"
  run run_script
  [ "$(calls_of repo-research-protocol)" -eq 0 ]
  grep -q 'API spend gate failed' "$(log_file)"
  assert_unchecked_stop_notified
}

@test "non-UTF-8 byte in the ledger: the gate logs the line number as a gate failure, not a cap stop" {
  # 以前は spend-gate が UnicodeDecodeError の traceback で rc 1 になり、billing_gate が rc 1 を
  # 「上限で止めた」と読んで stderr を捨て、金額の空の WARN (month $ / ...) だけが log に残っていた
  mkdir -p "$P/state"
  printf '{"date":"2026-11-01","cost_usd":1}\n\xff\n' > "$(ledger)"
  run run_script
  [ "$(calls_of repo-research-protocol)" -eq 0 ]
  grep -qF 'API spend gate failed (rc 2): spend-gate: 1 unreadable line(s) in' "$(log_file)"
  grep -qF 'line 2 (not UTF-8) — cannot check the caps' "$(log_file)"
  refute_grep -q 'Traceback' "$(log_file)"
  refute_grep -qF 'month $ /' "$(log_file)"
}

@test "ledger row without cost_usd: the gate stops instead of counting it as \$0" {
  # spend-add は cost_usd を必ず書く。手で編集して消えた行を 0 ドルに数えると上限の判定が甘くなる
  mkdir -p "$P/state"
  echo '{"date":"2026-11-01","line":"akc","call":"call1"}' > "$(ledger)"
  run run_script
  [ "$(calls_of repo-research-protocol)" -eq 0 ]
  grep -qF 'API spend gate failed (rc 2): spend-gate: 1 unreadable line(s) in' "$(log_file)"
  grep -qF 'line 1 (no cost_usd)' "$(log_file)"
}

@test "ledger row without date: the gate stops instead of leaving its cost out of the month" {
  # 月の上限 190 に対し、date の無い 186 ドルの行は以前どの累計にも入らず、line が始まっていた
  mkdir -p "$P/state"
  echo '{"line":"akc","call":"call1","cost_usd":186}' > "$(ledger)"
  run run_script
  [ "$(calls_of repo-research-protocol)" -eq 0 ]
  grep -qF 'API spend gate failed (rc 2): spend-gate: 1 unreadable line(s) in' "$(log_file)"
  grep -qF 'line 1 (no date)' "$(log_file)"
}

@test "ledger cannot be written: the run stops before the next line" {
  mkdir -p "$P/state/api-spend.jsonl"   # ディレクトリにして追記を失敗させる
  run run_script
  [ "$(calls_of repo-research-protocol)" -eq 0 ]
  grep -q 'could not record API spend' "$(log_file)"
  assert_unchecked_stop_notified
}

@test "the ledger becomes unwritable after the first line: the second line's stop is not called a cap stop" {
  # 1 本目の呼1 が台帳をディレクトリに替える (その呼び出しの費用の追記が失敗する)。上限には遠い
  echo "ledger-breaks" > "$MOCK_HOME/.scenario"
  run run_script
  [ "$(calls_of repo-research-protocol)" -eq 1 ]
  grep -q 'could not record API spend' "$(log_file)"
  grep -qF 'WARN: API spend gate could not check the caps' "$(log_file)"
  grep -qF 'API 支出を確かめられなかったため、' "$MOCK_HOME/.notify_log"
  refute_grep -qF '上限に達した' "$MOCK_HOME/.notify_log"
  grep -q '未実行: [a-z]*' "$MOCK_HOME/.notify_log"
}

# === check-auth.sh ===

@test "check-auth.sh in api mode probes with the key and prints the month's spend" {
  run env HOME="$MOCK_HOME" bash "$P/scripts/check-auth.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Billing mode: api"* ]]
  [[ "$output" == *"OK: Claude authentication is valid"* ]]
  [[ "$output" == *"API spend: today"* ]]
  [[ "$output" != *"$FAKE_KEY"* ]]
  grep -q "kind=probe key=$FAKE_KEY" "$MOCK_HOME/.calls"
}

@test "check-auth.sh in api mode reports a rejected key" {
  echo "probe-401" > "$MOCK_HOME/.scenario"
  run env HOME="$MOCK_HOME" bash "$P/scripts/check-auth.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Claude API rejected the request"* ]]
}

# === ERR trap (誤った「予期せず中断」通知) ===

@test "lint hard fail from another tool's note in the vault does not fire the unexpected-exit alert" {
  # 2026-10-29: 同じ vault dir の jrp ノート (ソース節なし) で report-lint が exit 2 →
  # `|| LINT_EXIT=$?` で処理しているのに $(…) 内で ERR trap が走り誤通知が出た
  mkdir -p "$MOCK_HOME/vault/daily-research"
  printf -- '---\nkind: report\n---\n本文だけ\n' > "$MOCK_HOME/vault/daily-research/${DR_DATE}_jrp_x.md"
  run run_script
  [ "$status" -eq 0 ]
  grep -q 'report lint hard fail (ctl-016)' "$(log_file)"
  if grep -q 'unexpected exit' "$(log_file)"; then cat "$(log_file)" >&2; return 1; fi
  if grep -q 'Daily Research Error' "$MOCK_HOME/.notify_log"; then cat "$MOCK_HOME/.notify_log" >&2; return 1; fi
}
