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
  # 課金経路の probe: cwd と flag を記録し、init の後は「応答の生成」(sleep) に入る。probe が init で
  # 止めれば .probe_completed は書かれない。.key_cwd の dir で起動されたときだけ key の経路を名乗る
  printf '%s\t%s\n' "$(pwd -P)" "$*" >> "$H/.probes"
  KS=$(cat "$H/.key_source")
  if [ -f "$H/.key_cwd" ] && [ "$(pwd -P)" = "$(cat "$H/.key_cwd")" ]; then KS=ANTHROPIC_API_KEY; fi
  echo "{\"type\":\"system\",\"subtype\":\"init\",\"apiKeySource\":\"$KS\"}"
  sleep 20
  echo '{"type":"result","is_error":false}'
  touch "$H/.probe_completed"
  exit 0
fi
# 本番の result JSON の OAuth の印 (.no_oauth_marker があると呼1 の result から外す)
MARK=',"credential_expires_at":"2026-12-01T00:00:00Z"'
CALL1_MARK=$MARK
[ -f "$H/.no_oauth_marker" ] && CALL1_MARK=""
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
    echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.5,"num_turns":20,"duration_ms":1000,"usage":{"input_tokens":10,"output_tokens":100}'"$CALL1_MARK"'}'
    ;;
  *verification-protocol.md)
    NOTE=$(printf '%s\n' "$PROMPT" | sed -n 's/^対象ファイル (原稿): //p')
    VERIFY=$(printf '%s\n' "$PROMPT" | sed -n 's/^検証結果の書き込み先: //p')
    sleep 3  # sandbox-run の原稿の写し (1 秒ごとの監視) が先に取れること
    echo "呼2 の改稿" >> "$NOTE"
    echo '{"supported": 1, "partial": 0, "unsupported": 0, "unverifiable": 0, "edits": 1}' > "$VERIFY"
    echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1,"num_turns":5,"duration_ms":1000,"usage":{"input_tokens":5,"output_tokens":50}'"$MARK"'}'
    ;;
  *)
    echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.001,"num_turns":1'"$MARK"'}'
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
  # env_file は sandbox の専用 subdir の存在しない path (本物の key file を指さない)
  grep -q "^env_file = \"$(cd "$OUT" && pwd -P)/sandbox/no-api-key/env\"" "$OUT/sandbox/project/config.toml"
  refute_grep -q "no-such-env" "$OUT/sandbox/project/config.toml"
  [ ! -e "$OUT/sandbox/no-api-key" ]
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
  # 課金経路の probe: 本番の 3 条件 (呼1 = 接地 repo + safe mode / 呼2 = PROJECT_DIR + safe mode /
  # auth probe = PROJECT_DIR) で 1 回ずつ。どれも init で止めた (応答の生成まで走っていない)
  [ ! -f "$MOCK_HOME/.probe_completed" ]
  [ "$(wc -l < "$MOCK_HOME/.probes" | tr -d ' ')" = "3" ]
  local proj repo
  proj="$(cd "$OUT" && pwd -P)/sandbox/project"
  repo="$(cd "$REPO" && pwd -P)"
  [ "$(sed -n 1p "$MOCK_HOME/.probes" | cut -f1)" = "$repo" ]
  sed -n 1p "$MOCK_HOME/.probes" | grep -q -- '--safe-mode'
  [ "$(sed -n 2p "$MOCK_HOME/.probes" | cut -f1)" = "$proj" ]
  sed -n 2p "$MOCK_HOME/.probes" | grep -q -- '--safe-mode'
  [ "$(sed -n 3p "$MOCK_HOME/.probes" | cut -f1)" = "$proj" ]
  refute_grep -q -- '--safe-mode' <<< "$(sed -n 3p "$MOCK_HOME/.probes")"
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert [r["ok"] for r in m["call_auth"]] == [True, True], m["call_auth"]' "$OUT/meta.json"
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
  # 最初の probe で止め、応答の生成まで走らせていない・残りの probe は起動しない
  [ ! -f "$MOCK_HOME/.probe_completed" ]
  [ "$(wc -l < "$MOCK_HOME/.probes" | tr -d ' ')" = "1" ]
}

@test "sandbox-run: a key supplied only in call 1's cwd (the target repo) is caught before the run" {
  (cd "$REPO" && pwd -P) > "$MOCK_HOME/.key_cwd"
  run_sandbox
  [ "$status" -eq 2 ]
  [ ! -f "$OUT/sandbox/project/logs/2026-08-13.log" ]
  grep -q $'^auth_probe_call1\tANTHROPIC_API_KEY' "$OUT/sandbox/meta.tsv"
}

@test "sandbox-run: a call result without the OAuth marker makes the run invalid" {
  touch "$MOCK_HOME/.no_oauth_marker"
  run_sandbox
  [ "$status" -eq 2 ]
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["valid"] is False and [r["ok"] for r in m["call_auth"]] == [False, True], m["call_auth"]' "$OUT/meta.json"
}

@test "sandbox-run: a symlinked state dir is copied as real files, so writes stay in the sandbox" {
  mv "$FAKE_MAIN/state/demo" "$MOCK_HOME/state-demo-real"
  ln -s "$MOCK_HOME/state-demo-real" "$FAKE_MAIN/state/demo"
  run_sandbox --prepare-only
  [ "$status" -eq 0 ]
  [ ! -L "$OUT/sandbox/project/state/demo" ]
  [ -z "$(find "$OUT/sandbox/project/state/demo" -type l)" ]
  [ "$(cat "$OUT/sandbox/project/state/demo/pending.md")" = "pending" ]
}

@test "sandbox-run: refuses an output dir in the real vault or in a tracked git tree, before creating it" {
  # 使い捨て repo の git init と sandbox-run の git check-ignore が呼び出し元の GIT_* を継承しない
  isolate_git_env
  HOME="$MOCK_HOME" run "$REAL_PROJECT_DIR/scripts/dev/sandbox-run.sh" --line demo --tree "$REAL_PROJECT_DIR" \
    --main "$FAKE_MAIN" --out "$MOCK_HOME/real-vault/daily-research/new/x" --prepare-only
  [ "$status" -eq 1 ]
  [ ! -e "$MOCK_HOME/real-vault/daily-research/new" ]
  git init -q "$MOCK_HOME/pub"
  HOME="$MOCK_HOME" run "$REAL_PROJECT_DIR/scripts/dev/sandbox-run.sh" --line demo --tree "$REAL_PROJECT_DIR" \
    --main "$FAKE_MAIN" --out "$MOCK_HOME/pub/runs/x" --prepare-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"not ignored"* ]]
  [ ! -e "$MOCK_HOME/pub/runs" ]
  # ignore された場所なら作る
  echo "runs/" > "$MOCK_HOME/pub/.gitignore"
  HOME="$MOCK_HOME" run "$REAL_PROJECT_DIR/scripts/dev/sandbox-run.sh" --line demo --tree "$REAL_PROJECT_DIR" \
    --main "$FAKE_MAIN" --out "$MOCK_HOME/pub/runs/x" --prepare-only
  [ "$status" -eq 0 ]
  [ -d "$MOCK_HOME/pub/runs/x/sandbox/project" ]
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
