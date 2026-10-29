#!/usr/bin/env bats
# API 課金 ([billing]、lib/billing.sh) のテスト: classify_exit の課金系の分類と、mock claude を使った
# orchestrator / check-auth.sh の E2E (key の受け渡し・呼び出しごとの上限・支出台帳・月/日の上限・
# 429 とクレジット切れでの停止)。
# mock は quiet の receipt だけを書く — ノート・呼2 の経路は test-e2e-mock.bats が持つ。

REAL_PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIB_DIR="$REAL_PROJECT_DIR/scripts/lib"
DR_PY="$LIB_DIR/dr_pipeline.py"
FAKE_KEY="test-key-e2e-0000"

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
R=$(printf '%s' "$PROMPT" | grep -oE '/[^ ]*/state/[A-Za-z0-9_-]+/runs/[0-9]{4}-[0-9]{2}-[0-9]{2}\.json' | head -1)
L=$(basename "$(dirname "$(dirname "$R")")"); D=$(basename "$R" .json)
case "$SC" in
  timeout)
    exit 124 ;;
  note-then-429)
    # ノートと article の receipt を書いた後に 429 で落ちる (呼2 の対象が残る形)
    V=$(printf '%s' "$PROMPT" | grep -oE '1\. レポート: [^ ]+' | head -1 | sed 's/^1\. レポート: //')
    VD=$(dirname "$V"); mkdir -p "$VD"
    printf -- '---\nkind: article\n---\nbody\n' > "$VD/${D}_${L}_note.md"
    printf '{"date":"%s","line":"%s","status":"article","report":"%s_%s_note.md","question":"q","reason":"r","reason_code":"no_new_evidence"}' "$D" "$L" "$D" "$L" > "$R"
    echo '{"type":"result","is_error":true,"api_error_status":429,"total_cost_usd":1.0,"result":"rate_limit_error"}'
    exit 1 ;;
  rate-limit)
    echo '{"type":"result","is_error":true,"api_error_status":429,"total_cost_usd":0.3,"result":"rate_limit_error"}'
    exit 1 ;;
  credit)
    echo '{"type":"result","is_error":true,"api_error_status":400,"total_cost_usd":0,"result":"Your credit balance is too low to access the Anthropic API."}'
    exit 1 ;;
  budget)
    echo '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":4.1,"errors":["Reached maximum budget ($4)"]}'
    exit 1 ;;
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
  grep -q '上限' "$MOCK_HOME/.notify_log"
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
}

@test "ledger cannot be written: the run stops before the next line" {
  mkdir -p "$P/state/api-spend.jsonl"   # ディレクトリにして追記を失敗させる
  run run_script
  [ "$(calls_of repo-research-protocol)" -eq 0 ]
  grep -q 'could not record API spend' "$(log_file)"
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
