#!/usr/bin/env bats
# 文書が正本の値を書き写していないことの機械ゲート (plan happy-growing-bachman「正本と参照」ゲート 1)。
# 値の正本は config.toml (私的) / config.example.toml / scripts / 支出台帳。文書はキー名や file で指す。
# ADR・docs/plans/・docs/design/ は日付付きの記録なので対象外。fenced code block (shell の例) は除く。

load test_helper

PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DOCS=(
  CLAUDE.md README.md README.ja.md
  docs/RUNBOOK.md docs/RUNBOOK.ja.md docs/CONTRIB.md docs/CONTRIB.ja.md
  llms.txt SKILL.md .claude/skills/dr-review/SKILL.md
)

# fenced code block の外の行を "file:line: text" で出す
prose_lines() {
  local f
  for f in "${DOCS[@]}"; do
    [ -f "$PROJECT_DIR/$f" ] || continue
    awk -v F="$f" '/^[[:space:]]*```/ { fence = !fence; next } !fence { print F ":" NR ": " $0 }' "$PROJECT_DIR/$f"
  done
}

@test "docs: no copied lines_per_day value" {
  refute_grep -E 'lines_per_day *= *[0-9]' <<< "$(prose_lines)"
}

@test "docs: no dollar amounts (cost lives in the spend ledger and check-auth.sh)" {
  refute_grep -E '\$[0-9]' <<< "$(prose_lines)"
}

@test "docs: no fixed number of reports per day" {
  refute_grep -Ei '1 日 *[0-9]+ *本|毎朝 *[0-9]+ *本|連続 *[0-9]+ *本|[0-9]+ *本 */ *日|([0-9]+|one|two|three|four|five|six|seven) (lines? |reports? |runs? )?(per|a|each) (day|morning)|(one|two|three|four|five|six|seven) by default' <<< "$(prose_lines)"
}

@test "docs: no line names from the private config (list them with dr_pipeline.py tracks)" {
  [ -f "$PROJECT_DIR/config.toml" ] || skip "config.toml が無い checkout"
  local text name
  text=$(prose_lines)
  while IFS=$'\t' read -r name _; do
    [ -n "$name" ] || continue
    refute_grep -F "\`$name\`" <<< "$text"
  done < <(python3 "$PROJECT_DIR/scripts/lib/dr_pipeline.py" tracks "$PROJECT_DIR/config.toml")
}
