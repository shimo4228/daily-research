#!/usr/bin/env bats
# scripts/dev/sandbox-run.sh (隔離 run の道具) の E2E。mock claude を $MOCK_HOME/.local/bin に置き、
# HOME を差し替えて走らせる (sandbox-run.sh の掃除した PATH は $HOME/.local/bin を含む)。
# 本物の claude・vault・MAIN の私的ファイルには触れない — MAIN も vault も mktemp の中の作り物。

REAL_PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

load test_helper

setup() {
  MOCK_HOME="$(mktemp -d)"
  FAKE_MAIN="$MOCK_HOME/main"
  REPO="$MOCK_HOME/repos/demo"
  OUT="$MOCK_HOME/out"
  mkdir -p "$FAKE_MAIN/state/demo/runs" "$REPO" "$MOCK_HOME/real-vault/daily-research" "$MOCK_HOME/.local/bin"
  cat > "$FAKE_MAIN/config.toml" << EOF
[general]
vault_path = "$MOCK_HOME/real-vault"
output_dir = "daily-research"

[billing]
mode = "api"
env_file = "$MOCK_HOME/no-such-env"

[tracks.demo]
name = "Demo"
focus = "demo focus"

[[tracks.demo.repos]]
key = "demo"
target_repo = "$REPO"
EOF
  echo '{"topics": [{"date": "2026-08-01", "track": "demo", "question": "前の問い"}]}' > "$FAKE_MAIN/past_topics.json"
  echo "brief" > "$FAKE_MAIN/state/demo/brief.md"
  echo "pending" > "$FAKE_MAIN/state/demo/pending.md"
  echo '{"stale": true}' > "$FAKE_MAIN/state/demo/runs/2026-08-13.json"
  echo "none" > "$MOCK_HOME/.key_source"
  create_mock_claude
}

teardown() {
  rm -rf "$MOCK_HOME"
}

# 呼び分け: stream-json = 課金経路の事前確認 / protocol なし = auth probe / research protocol = 呼1 /
# verification protocol = 呼2。書き込み先はプロンプトの「書き込み先」節と呼2 のパス行から読む
create_mock_claude() {
  cat > "$MOCK_HOME/.local/bin/claude" << 'MOCK'
#!/bin/bash
H="$(dirname "$(dirname "$(dirname "$0")")")"
[ "$1" = "--version" ] && { echo "0.0.0 (mock)"; exit 0; }
PROMPT=""; PROTOCOL=""; FORMAT=""; PREV=""
for a in "$@"; do
  case "$PREV" in
    -p) PROMPT="$a" ;;
    --append-system-prompt-file) PROTOCOL="$a" ;;
    --output-format) FORMAT="$a" ;;
  esac
  PREV="$a"
done
# CLAUDE_TIMEOUT は daily-research.sh 自身が run_claude に付ける (持ち込みではない)
env | grep -E '^(ANTHROPIC|CLAUDE)' | grep -v '^CLAUDE_TIMEOUT=' >> "$H/.leaked_env" || true
if [ "$FORMAT" = "stream-json" ]; then
  echo "{\"type\":\"system\",\"subtype\":\"init\",\"apiKeySource\":\"$(cat "$H/.key_source")\"}"
  echo '{"type":"result","is_error":false}'
  exit 0
fi
case "$PROTOCOL" in
  *research-protocol.md)
    TRACK=$(printf '%s\n' "$PROMPT" | sed -n 's/^- line (track): //p' | head -1)
    DATE=$(printf '%s\n' "$PROMPT" | sed -n 's/^- 本日の日付: //p' | head -1)
    REPORT_DIR=$(printf '%s\n' "$PROMPT" | sed -n 's|^- \(.*\)/\*\*$|\1|p' | head -1)
    RUNS=$(printf '%s\n' "$PROMPT" | sed -n 's|^- \(.*/runs\)/\*\*$|\1|p' | head -1)
    NOTE="${DATE}_${TRACK}_mock-note.md"
    printf -- '---\nkind: article\n---\n\n# t\n\n2026-08-13 に起きた出来事。\n\n## 機会メモ\n\nなし\n\n## ソース\n\n- [a](https://example.com/a)\n' > "$REPORT_DIR/$NOTE"
    printf '| C1 | p | u | d | l | e | s | o | p | 本文確認済 |\n' > "$RUNS/$DATE.md"
    printf '{"date":"%s","line":"%s","status":"article","report":"%s","question":"新しい問い","reason":"","reason_code":"unspecified","answer_scope":"a","title":"t"}' \
      "$DATE" "$TRACK" "$NOTE" > "$RUNS/$DATE.json"
    echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.5,"num_turns":20,"duration_ms":1000,"usage":{"input_tokens":10,"output_tokens":100}}'
    ;;
  *verification-protocol.md)
    NOTE=$(printf '%s\n' "$PROMPT" | sed -n 's/^対象ファイル (原稿): //p')
    VERIFY=$(printf '%s\n' "$PROMPT" | sed -n 's/^検証結果の書き込み先: //p')
    sleep 3  # sandbox-run の原稿の写し (1 秒ごとの監視) が先に取れること
    echo "呼2 の改稿" >> "$NOTE"
    echo '{"supported": 1, "partial": 0, "unsupported": 0, "unverifiable": 0, "edits": 1}' > "$VERIFY"
    echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1,"num_turns":5,"duration_ms":1000,"usage":{"input_tokens":5,"output_tokens":50}}'
    ;;
  *)
    echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.001,"num_turns":1}'
    ;;
esac
MOCK
  chmod +x "$MOCK_HOME/.local/bin/claude"
}

run_sandbox() {
  HOME="$MOCK_HOME" run "$REAL_PROJECT_DIR/scripts/dev/sandbox-run.sh" --line demo --date 2026-08-13 \
    --tree "$REAL_PROJECT_DIR" --main "$FAKE_MAIN" --out "$OUT" "$@"
}

@test "sandbox-run: one line end to end in the sandbox, artifacts collected, nothing written outside" {
  run_sandbox
  [ "$status" -eq 0 ]
  grep -q '^mode = "subscription"' "$OUT/sandbox/project/config.toml"
  grep -q "^vault_path = \"$(cd "$OUT" && pwd -P)/sandbox/vault\"" "$OUT/sandbox/project/config.toml"
  # 成果物: 最終版のノートと呼1 の原稿 (呼2 の改稿を含まない)
  [ -f "$OUT/2026-08-13_demo_mock-note.md" ]
  grep -q "呼2 の改稿" "$OUT/2026-08-13_demo_mock-note.md"
  refute_grep -q "呼2 の改稿" "$OUT/draft.md"
  for f in receipt.json evidence.md verify.json run.log metrics.json call1.json call2.json meta.json past_topics.line.json; do
    [ -f "$OUT/$f" ] || { echo "missing $f"; false; }
  done
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["valid"] and m["draft"] == "clean" and m["dr_exit"] == 0, m' "$OUT/meta.json"
  grep -q "Billing: subscription" "$OUT/run.log"
  # 通知は shim が受けた (本物の osascript は呼ばれない)
  grep -q "display notification" "$OUT/notifications.log"
  # 掃除した環境: ANTHROPIC_* / CLAUDE* は claude に届かない
  [ ! -s "$MOCK_HOME/.leaked_env" ]
  # 当日の古い receipt は写さない。本物側の vault・state は無変更
  [ -z "$(ls -A "$MOCK_HOME/real-vault/daily-research")" ]
  grep -q '"stale": true' "$FAKE_MAIN/state/demo/runs/2026-08-13.json"
  [ "$(cat "$FAKE_MAIN/state/demo/pending.md")" = "pending" ]
  # eval_run が出力 dir を読める
  python3 "$REAL_PROJECT_DIR/scripts/dev/eval_run.py" "$OUT" --write > /dev/null
  python3 -c 'import json,sys; e=json.load(open(sys.argv[1])); assert e["receipt"]["valid"] and e["verify"]["supported"] == 1 and e["call1"]["turns"] == 20, e' "$OUT/eval.json"
}

@test "sandbox-run: refuses to run when the probe does not see OAuth (apiKeySource != none)" {
  echo "ANTHROPIC_API_KEY" > "$MOCK_HOME/.key_source"
  run_sandbox
  [ "$status" -eq 2 ]
  [ ! -f "$OUT/sandbox/project/logs/2026-08-13.log" ]
}

@test "sandbox-run: refuses a non-empty output dir and a missing line" {
  mkdir -p "$OUT" && touch "$OUT/x"
  run_sandbox --prepare-only
  [ "$status" -eq 1 ]
  rm -rf "$OUT"
  HOME="$MOCK_HOME" run "$REAL_PROJECT_DIR/scripts/dev/sandbox-run.sh" --line nosuch \
    --tree "$REAL_PROJECT_DIR" --main "$FAKE_MAIN" --out "$OUT" --prepare-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in config.toml"* ]]
}
