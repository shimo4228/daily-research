#!/usr/bin/env bats
# Real shell/Python/CLI integration in a disposable filesystem, without network.
setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CASE_DIR="$(mktemp -d)"
  APP="$CASE_DIR/app"
  mkdir -p "$APP/scripts" "$APP/prompts" "$CASE_DIR/bin" "$CASE_DIR/vault/scripts"
  cp "$REPO/scripts/daily-research.sh" "$APP/scripts/"
  cp -R "$REPO/scripts/lib" "$APP/scripts/"
  cp "$REPO/prompts/"*.md "$APP/prompts/"
  cp "$REPO/tests/fixtures/discovery-mock-claude" "$CASE_DIR/bin/mock-claude"
  printf 'A reader interested in unknown possibilities.\n' > "$APP/reader-profile.md"
  cat > "$APP/config.toml" <<CFG
[general]
vault_path = "$CASE_DIR/vault"
output_dir = "daily-research"
[reader]
profile = "reader-profile.md"
[research]
timeout_seconds = 1
[editorial]
timeout_seconds = 1
CFG
  cat > "$CASE_DIR/bin/osascript" <<'MOCK'
#!/bin/bash
printf 'notify\n' >> "$DR_MOCK_NOTIFY"
MOCK
  cat > "$CASE_DIR/vault/scripts/daily_wiki_ingest.sh" <<'MOCK'
#!/bin/bash
printf '%s\n' "$1" >> "$DR_MOCK_INGEST"
MOCK
  chmod +x "$CASE_DIR/bin/osascript" "$CASE_DIR/vault/scripts/daily_wiki_ingest.sh"
  export PATH="$CASE_DIR/bin:$PATH"
  export DR_MOCK_TRACE="$CASE_DIR/calls.jsonl"
  export DR_MOCK_NOTIFY="$CASE_DIR/notifications"
  export DR_MOCK_INGEST="$CASE_DIR/ingests"
  export DR_MOCK_SCENARIO=normal
  TODAY="$(date +%Y-%m-%d)"
  SCRIPT="$APP/scripts/daily-research.sh"
  MOCK="$CASE_DIR/bin/mock-claude"
}
teardown() { rm -rf "$CASE_DIR"; }

@test "preview isolates outputs and model context" {
  run bash "$SCRIPT" --preview --claude "$MOCK"
  [ "$status" -eq 0 ]
  [ ! -e "$APP/metrics.jsonl" ]
  [ ! -e "$APP/state" ]
  [ ! -e "$CASE_DIR/vault/daily-research" ]
  [ ! -e "$DR_MOCK_NOTIFY" ]
  [ ! -e "$DR_MOCK_INGEST" ]
  python3 - "$DR_MOCK_TRACE" <<'PY'
import json,sys
calls=[json.loads(line) for line in open(sys.argv[1])]
assert len(calls)==2
assert 'history' not in calls[0]['payload']
assert 'history' in calls[1]['payload']
for call in calls:
    args=call['args']
    assert '--safe-mode' in args
    assert args[args.index('--tools')+1]=='WebSearch,WebFetch'
    assert 'repo' not in call['payload'] and 'playbook' not in call['payload']
PY
}
@test "publication happens once and preserves ingest frontmatter" {
  run bash "$SCRIPT" --claude "$MOCK"
  [ "$status" -eq 0 ]
  REPORT="$CASE_DIR/vault/daily-research/${TODAY}_discovery_edition.md"
  [ -s "$REPORT" ]
  grep -q '^category: discovery' "$REPORT"
  grep -q '^topic:' "$REPORT"
  grep -q '^actionable: 0' "$REPORT"
  [ "$(wc -l < "$DR_MOCK_INGEST" | tr -d ' ')" -eq 1 ]
  run bash "$SCRIPT" --claude "$MOCK"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$DR_MOCK_TRACE" | tr -d ' ')" -eq 2 ]
  [ "$(wc -l < "$DR_MOCK_INGEST" | tr -d ' ')" -eq 1 ]
  [ "$(wc -l < "$APP/metrics.jsonl" | tr -d ' ')" -eq 1 ]
}
@test "quiet is successful private completion, not wiki input" {
  export DR_MOCK_SCENARIO=quiet
  run bash "$SCRIPT" --claude "$MOCK"
  [ "$status" -eq 0 ]
  [ -f "$APP/state/discovery/${TODAY}.quiet.json" ]
  [ ! -e "$CASE_DIR/vault/daily-research" ]
  [ ! -e "$DR_MOCK_INGEST" ]
}
@test "invalid editor references fail without publishing" {
  export DR_MOCK_SCENARIO=invalid
  run bash "$SCRIPT" --claude "$MOCK"
  [ "$status" -ne 0 ]
  [ ! -e "$CASE_DIR/vault/daily-research" ]
  [ ! -e "$DR_MOCK_INGEST" ]
  grep -q E_NO_REPORT "$APP/metrics.jsonl"
}
@test "auth failure makes no research calls" {
  export DR_MOCK_SCENARIO=auth
  run bash "$SCRIPT" --claude "$MOCK"
  [ "$status" -ne 0 ]
  [ ! -e "$DR_MOCK_TRACE" ]
  [ ! -e "$DR_MOCK_INGEST" ]
}
@test "transient retries once and preserves both attempt costs" {
  export DR_MOCK_SCENARIO=transient
  run bash "$SCRIPT" --claude "$MOCK"
  [ "$status" -eq 0 ]
  python3 - "$APP/metrics.jsonl" <<'PY'
import json,sys
m=json.loads(open(sys.argv[1]).read())
assert m['fallback_used']
assert m['stages']['research']['attempts']==2
assert m['total_cost']==0.4
PY
}
@test "time budget exhaustion fails without retry or publication" {
  export DR_MOCK_SCENARIO=timeout
  run bash "$SCRIPT" --claude "$MOCK"
  [ "$status" -ne 0 ]
  [ "$(wc -l < "$DR_MOCK_TRACE" | tr -d ' ')" -eq 1 ]
  [ ! -e "$CASE_DIR/vault/daily-research" ]
  [ ! -e "$DR_MOCK_INGEST" ]
}
