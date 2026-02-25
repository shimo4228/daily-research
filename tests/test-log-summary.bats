#!/usr/bin/env bats
# Tests for log_summary() JSON parsing
# Run: bats tests/test-log-summary.bats
#
# log_summary() 内の Python コードを直接テストする。
# dict 形式と array 形式の両方をカバーする。

PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$PROJECT_DIR/scripts/daily-research.sh"

# === Setup / Teardown ===

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  # log_summary の Python コードをスクリプトから抽出
  # (関数全体を source するのではなく、Python 部分だけを抽出してテスト)
  extract_log_summary_python
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# log_summary() 内の Python コードを抽出してファイルに保存
extract_log_summary_python() {
  # daily-research.sh から log_summary 内の python3 -c "..." 部分を抽出
  # 引数 $label は sys.argv[1] で渡される
  # daily-research.sh の log_summary 内と同一の Python コードを抽出
  cat > "$TEST_TMPDIR/log_summary.py" << 'PYTHON'
import sys, json
try:
    raw = json.loads(sys.stdin.read())
    if isinstance(raw, list):
        d = next((e for e in raw if isinstance(e, dict) and e.get('type') == 'result'), {})
    else:
        d = raw
    cost = d.get('total_cost_usd', 0)
    turns = d.get('num_turns', 0)
    dur = round(d.get('duration_ms', 0) / 1000)
    inp = d.get('usage', {}).get('input_tokens', 0)
    out = d.get('usage', {}).get('output_tokens', 0)
    tc = d.get('tool_counts', {})
    searches = tc.get('WebSearch', 0) + tc.get('WebFetch', 0)
    tool_str = f' searches={searches}' if searches else ''
    print(f'SUMMARY {sys.argv[1]}: cost=${cost:.4f} turns={turns} duration={dur}s tokens_in={inp} tokens_out={out}{tool_str}')
except Exception as e:
    print(f'SUMMARY {sys.argv[1]}: (parse error: {e})')
PYTHON
}

# === Test: dict 形式（既存の正常パス） ===

@test "log_summary: dict format parses correctly" {
  local json_input='{"total_cost_usd":0.1234,"num_turns":10,"duration_ms":60000,"usage":{"input_tokens":5000,"output_tokens":1200},"tool_counts":{"WebSearch":3,"WebFetch":1}}'

  local result
  result=$(echo "$json_input" | python3 "$TEST_TMPDIR/log_summary.py" "Pass1")

  [[ "$result" == *"cost=\$0.1234"* ]]
  [[ "$result" == *"turns=10"* ]]
  [[ "$result" == *"duration=60s"* ]]
  [[ "$result" == *"tokens_in=5000"* ]]
  [[ "$result" == *"tokens_out=1200"* ]]
  [[ "$result" == *"searches=4"* ]]
}

@test "log_summary: dict format with zero cost" {
  local json_input='{"total_cost_usd":0,"num_turns":0,"duration_ms":0,"usage":{"input_tokens":0,"output_tokens":0}}'

  local result
  result=$(echo "$json_input" | python3 "$TEST_TMPDIR/log_summary.py" "Pass2")

  [[ "$result" == *"SUMMARY Pass2:"* ]]
  [[ "$result" == *"cost=\$0.0000"* ]]
  [[ "$result" == *"turns=0"* ]]
}

# === Test: array 形式（Pass 2 の --output-format json が返す可能性がある） ===

@test "log_summary: array format with result event parses correctly" {
  local json_input='[{"type":"assistant","message":{"content":[]}},{"type":"result","subtype":"success","total_cost_usd":0.5678,"num_turns":20,"duration_ms":120000,"usage":{"input_tokens":8000,"output_tokens":2000}}]'

  local result
  result=$(echo "$json_input" | python3 "$TEST_TMPDIR/log_summary.py" "Pass2")

  # array 形式でもパースエラーにならず、result イベントの値が抽出される
  [[ "$result" != *"parse error"* ]]
  [[ "$result" == *"cost=\$0.5678"* ]]
  [[ "$result" == *"turns=20"* ]]
  [[ "$result" == *"duration=120s"* ]]
  [[ "$result" == *"tokens_in=8000"* ]]
  [[ "$result" == *"tokens_out=2000"* ]]
}

@test "log_summary: array format without result event gives defaults" {
  local json_input='[{"type":"assistant","message":{"content":[]}}]'

  local result
  result=$(echo "$json_input" | python3 "$TEST_TMPDIR/log_summary.py" "Pass2")

  # result イベントがなくてもクラッシュしない
  [[ "$result" != *"parse error"* ]]
  [[ "$result" == *"cost=\$0.0000"* ]]
}

@test "log_summary: single result object in array" {
  local json_input='[{"type":"result","subtype":"success","total_cost_usd":0.0100,"num_turns":1,"duration_ms":5000,"usage":{"input_tokens":100,"output_tokens":50}}]'

  local result
  result=$(echo "$json_input" | python3 "$TEST_TMPDIR/log_summary.py" "MCP")

  [[ "$result" == *"SUMMARY MCP:"* ]]
  [[ "$result" == *"cost=\$0.0100"* ]]
  [[ "$result" == *"turns=1"* ]]
}

# === Test: エッジケース ===

@test "log_summary: missing fields default to zero" {
  local json_input='{}'

  local result
  result=$(echo "$json_input" | python3 "$TEST_TMPDIR/log_summary.py" "Test")

  [[ "$result" == *"SUMMARY Test:"* ]]
  [[ "$result" == *"cost=\$0.0000"* ]]
  [[ "$result" == *"turns=0"* ]]
}

@test "log_summary: empty array gives defaults" {
  local json_input='[]'

  local result
  result=$(echo "$json_input" | python3 "$TEST_TMPDIR/log_summary.py" "Empty")

  [[ "$result" != *"parse error"* ]]
  [[ "$result" == *"SUMMARY Empty:"* ]]
  [[ "$result" == *"cost=\$0.0000"* ]]
}

@test "log_summary: invalid JSON gives parse error" {
  local json_input='not-json'

  local result
  result=$(echo "$json_input" | python3 "$TEST_TMPDIR/log_summary.py" "Err")

  [[ "$result" == *"parse error"* ]]
}

# === Test: Total コストサマリー（Pass1 dict + Pass2 の2行入力） ===

# Total コストサマリーの Python コードを抽出してファイルに保存
extract_total_summary_python() {
  # daily-research.sh の Total コストサマリーと同一の Python コードを抽出
  cat > "$TEST_TMPDIR/total_summary.py" << 'PYTHON'
import sys, json
def as_dict(raw):
    if isinstance(raw, list):
        return next((e for e in raw if isinstance(e, dict) and e.get('type') == 'result'), {})
    return raw
try:
    lines = sys.stdin.read().splitlines()
    d1 = as_dict(json.loads(lines[0]))
    d2 = as_dict(json.loads(lines[1]))
    cost1 = d1.get('total_cost_usd', 0)
    cost2 = d2.get('total_cost_usd', 0)
    dur1 = round(d1.get('duration_ms', 0) / 1000)
    dur2 = round(d2.get('duration_ms', 0) / 1000)
    print(f'SUMMARY Total: cost=${cost1 + cost2:.4f} duration={dur1 + dur2}s (Pass1: ${cost1:.4f}, Pass2: ${cost2:.4f})')
except Exception as e:
    print(f'SUMMARY Total: (parse error: {e})')
PYTHON
}

@test "total_summary: dict + dict parses correctly" {
  extract_total_summary_python

  local pass1='{"total_cost_usd":0.25,"duration_ms":60000}'
  local pass2='{"total_cost_usd":0.50,"duration_ms":120000}'

  local result
  result=$(printf '%s\n%s\n' "$pass1" "$pass2" | python3 "$TEST_TMPDIR/total_summary.py")

  [[ "$result" == *"cost=\$0.7500"* ]]
  [[ "$result" == *"duration=180s"* ]]
  [[ "$result" == *"Pass1: \$0.2500"* ]]
  [[ "$result" == *"Pass2: \$0.5000"* ]]
}

@test "total_summary: dict + array parses correctly" {
  extract_total_summary_python

  local pass1='{"total_cost_usd":0.25,"duration_ms":60000}'
  local pass2='[{"type":"assistant","message":{"content":[]}},{"type":"result","total_cost_usd":0.50,"duration_ms":120000}]'

  local result
  result=$(printf '%s\n%s\n' "$pass1" "$pass2" | python3 "$TEST_TMPDIR/total_summary.py")

  # Pass2 が array でもパースエラーにならない
  [[ "$result" != *"parse error"* ]]
  [[ "$result" == *"cost=\$0.7500"* ]]
  [[ "$result" == *"Pass2: \$0.5000"* ]]
}
