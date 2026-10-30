#!/usr/bin/env bats
# Tests for daily-research project (per-repo in-context research, ADR-0008)
# Run: bats tests/test-daily-research.bats

# テストファイルからの相対パスでプロジェクトルートを解決
PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$PROJECT_DIR/scripts/daily-research.sh"

load test_helper

# === Setup / Teardown ===

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# === Syntax checks ===

@test "daily-research.sh has valid syntax" {
  bash -n "$SCRIPT"
}

@test "check-auth.sh has valid syntax" {
  bash -n "$PROJECT_DIR/scripts/check-auth.sh"
}

@test "entrypoints share real_auth_probe (no formalized --version auth)" {
  # auth-002: lib/auth.sh で正本化し共有 (bootstrap-graph.sh は ADR-0008 で retire)
  grep -q 'real_auth_probe' "$SCRIPT"
  grep -q 'real_auth_probe' "$PROJECT_DIR/scripts/check-auth.sh"
  refute_grep -qi 'version.*authentication\|authentication.*version' "$PROJECT_DIR/scripts/check-auth.sh"
}

# === Per-repo 実行の配線 (ADR-0008 / 輪番は ADR-0010) ===

@test "orchestrator picks the day's line via rotation-pick and runs claude with cwd=target_repo" {
  grep -q 'rotation-pick' "$SCRIPT"
  # cwd は mode が決める (ADR-0018): repo mode は target_repo、ecosystem mode は line の state dir
  grep -q 'LINE_CWD="\$TARGET_REPO"' "$SCRIPT"
  grep -q 'LINE_CWD="\$STATE_DIR"' "$SCRIPT"
  grep -q 'cd "\$LINE_CWD"' "$SCRIPT"
}

@test "orchestrator derives the execution form from [tracks.<x>].mode, never from a line name (ADR-0018)" {
  grep -q 'config-get "\$PROJECT_DIR/config.toml" "tracks.\$TRACK.mode" repo' "$SCRIPT"
  grep -q 'prompts/ecosystem-research-protocol.md' "$SCRIPT"
  grep -q -- '--safe-mode' "$SCRIPT"
  # line 名での特殊分岐が無い (config の line 名はコードに現れない)
  # 否定は `! grep` で書かない (set -e の対象外で、最終行以外は検出されない)
  if grep -qE '"\$TRACK" *=+ *"?(jev|edge|akc|desire|ans|aap|authorship|contemplative)"?' "$SCRIPT"; then false; fi
  if grep -qw 'jev' "$SCRIPT"; then false; fi
  if grep -qw 'jev' "$PROJECT_DIR/scripts/lib/dr_pipeline.py"; then false; fi
}

@test "orchestrator injects past themes and line brief into per-line prompt" {
  grep -q '過去テーマ履歴' "$SCRIPT"
  grep -q 'PAST_THEMES' "$SCRIPT"
  grep -q 'line-brief' "$SCRIPT"
}

@test "orchestrator restricts file writes to vault, state, and past_topics (repo read-only)" {
  # path 規則は Edit(path) だけが consult される仕様 — Write(path) 規則は書かない
  grep -q 'Edit(//' "$SCRIPT"
  # コメント行は除く — script 自身がこの仕様を `Write(path) 規則は無視される` と注記している
  if grep -v '^[[:space:]]*#' "$SCRIPT" | grep -q 'Write('; then
    false
  fi
  grep -q 'past_topics.json)' "$SCRIPT"
  # 無条件の Write/Edit (path 制限なし) を allowedTools に入れていない
  refute_grep -qE 'ALLOWED_TOOLS="[^"]*,(Write|Edit),' "$SCRIPT"
}

@test "orchestrator uses per-repo research protocol as system prompt" {
  grep -q 'append-system-prompt-file' "$SCRIPT"
  grep -q 'repo-research-protocol.md' "$SCRIPT"
}

@test "concept-graph selection machinery is retired (ADR-0008)" {
  refute_grep -q 'coverage-report' "$SCRIPT"
  refute_grep -q 'cluster-report' "$SCRIPT"
  refute_grep -q 'sync_repo_graphs' "$SCRIPT"
  refute_grep -q 'validate_theme_json' "$SCRIPT"
  [ ! -f "$PROJECT_DIR/scripts/coverage-report.sh" ]
  [ ! -f "$PROJECT_DIR/scripts/bootstrap-graph.sh" ]
  [ ! -f "$PROJECT_DIR/scripts/lib/graph.sh" ]
}

# === 新プロトコルの contract (repo-research-protocol.md) ===

@test "protocol selects a question-form theme and allows four content states (ADR-0017)" {
  grep -q '問いの形' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q '記事 / 短報 / 更新なし / 保留' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q '文の形で分ける' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q '承認要求・「〜すべき」・手順の列挙は書かない' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  # 使い道は選定のゲートにしない / 対立フレーミングは戻っていない
  grep -q 'ゲートにしない' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  refute_grep -q '前提挑戦パス' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  refute_grep -q '反証プレッシャー' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  refute_grep -q 'theme_rank' "$PROJECT_DIR/prompts/repo-research-protocol.md"
}

@test "protocol mandates short context, citation gate, self-signal guard, evidence file and receipt" {
  grep -q 'brief.md' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q 'last-attempt' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q 'citation ゲート' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q '自己汚染ガード' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q '根拠ファイル' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q 'reason_code' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q 'pending.md' "$PROJECT_DIR/prompts/repo-research-protocol.md"
}

@test "protocol declares repo read-only and forbids tactic quota" {
  grep -q 'repo は read-only' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q '発見のノルマは無い' "$PROJECT_DIR/prompts/repo-research-protocol.md"
}

@test "template has kind/question frontmatter, no fixed body headings, and fixed tail sections" {
  grep -q '冒頭は外部の出来事から' "$PROJECT_DIR/templates/report-template.md"
  grep -q '^kind: article' "$PROJECT_DIR/templates/report-template.md"
  grep -q '^question:' "$PROJECT_DIR/templates/report-template.md"
  grep -q '固定見出しは置かない' "$PROJECT_DIR/templates/report-template.md"
  refute_grep -q '^## 結論' "$PROJECT_DIR/templates/report-template.md"
  refute_grep -q '^## この repo への含意' "$PROJECT_DIR/templates/report-template.md"
  refute_grep -q 'theme_rank' "$PROJECT_DIR/templates/report-template.md"
  grep -q '## 機会メモ' "$PROJECT_DIR/templates/report-template.md"
  grep -q '## ソース' "$PROJECT_DIR/templates/report-template.md"
  grep -q '失効日' "$PROJECT_DIR/templates/report-template.md"
  grep -q '判定 source' "$PROJECT_DIR/templates/report-template.md"
}

@test "edge template is story-first with steal-section and fixed tail sections" {
  local T="$PROJECT_DIR/templates/report-template-edge.md"
  [ -f "$T" ]
  grep -q '事件から始める' "$T"
  grep -q '## 盗める手筋' "$T"
  # 逆リード・台帳神学の節は持たない
  refute_grep -q '## 結論' "$T"
  refute_grep -q '## この repo への含意' "$T"
  # 機械検査 (ctl-016) 対象の固定 2 節は共通テンプレと同じく必須
  grep -q '## 機会メモ' "$T"
  grep -q '## ソース' "$T"
  grep -q '失効日' "$T"
}

@test "protocol carries the reader-contract style rules (6 items)" {
  grep -q '文体規律' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q '第一文は外部の出来事' "$PROJECT_DIR/prompts/repo-research-protocol.md"
  grep -q '一文一命題' "$PROJECT_DIR/prompts/repo-research-protocol.md"
}

@test "orchestrator resolves per-track template with fallback to common template" {
  grep -q 'template-path' "$SCRIPT"
  grep -q 'LINE_TEMPLATE' "$SCRIPT"
}

# === Config files exist ===

@test "config.toml exists" {
  [ -f "$PROJECT_DIR/config.toml" ]
}

@test "repo-research-protocol.md exists (old prompts retired)" {
  [ -f "$PROJECT_DIR/prompts/repo-research-protocol.md" ]
  [ ! -f "$PROJECT_DIR/prompts/theme-selection-prompt.md" ]
  [ ! -f "$PROJECT_DIR/prompts/task-prompt.md" ]
  [ ! -f "$PROJECT_DIR/prompts/research-protocol.md" ]
}

@test "report-template.md exists" {
  [ -f "$PROJECT_DIR/templates/report-template.md" ]
}

# === launchd plist validation ===

@test "plist is valid XML" {
  plutil -lint "$PROJECT_DIR/com.shimomoto.daily-research.plist"
}

@test "plist points to correct script path" {
  plutil -extract ProgramArguments json \
    "$PROJECT_DIR/com.shimomoto.daily-research.plist" \
    -o - | grep -q "daily-research.sh"
}

@test "plist schedule is set to 5:00" {
  local hour
  hour=$(plutil -extract StartCalendarInterval.Hour raw \
    "$PROJECT_DIR/com.shimomoto.daily-research.plist")
  [ "$hour" = "5" ]
}

@test "morning brief is retired (ADR-0009)" {
  [ ! -f "$PROJECT_DIR/scripts/morning-brief.sh" ]
  [ ! -f "$PROJECT_DIR/com.example.daily-research-brief.plist" ]
  [ ! -f "$PROJECT_DIR/com.shimomoto.daily-research-brief.plist" ]
}

# === Lock mechanism ===

@test "orchestrator uses mkdir-atomic lock via lib/lock.sh" {
  grep -q 'source.*lock.sh' "$SCRIPT"
  grep -q 'acquire_lock' "$SCRIPT"
  refute_grep -q 'echo \$\$ > "\$LOCK_FILE"' "$SCRIPT"
}

# === Log directory ===

@test "logs directory exists" {
  [ -d "$PROJECT_DIR/logs" ]
}

@test "logs directory has permission 700" {
  local perms
  perms=$(stat -f "%Lp" "$PROJECT_DIR/logs")
  [ "$perms" = "700" ]
}

# === past_topics.json ===

@test "past_topics.json is valid JSON" {
  python3 -c "import json; json.load(open('$PROJECT_DIR/past_topics.json'))"
}

@test "past_topics.json backup exists" {
  [ -f "$PROJECT_DIR/past_topics.json.bak" ]
}

# === Security checks ===

@test "env.sh source declares unset ANTHROPIC_API_KEY (static)" {
  grep -q "unset ANTHROPIC_API_KEY" "$PROJECT_DIR/scripts/lib/env.sh"
}

@test "no hardcoded API keys in script" {
  refute_grep -qE '(sk-[a-zA-Z0-9]{20,}|api_key\s*=\s*"[^"]+")' "$SCRIPT"
}

@test "log file permissions are restricted (chmod 600)" {
  grep -q 'chmod 600 "$LOG_FILE"' "$PROJECT_DIR/scripts/lib/log.sh"
}

# === Defensive programming ===

@test "set -Eeuo pipefail is configured (-E: ERR trap reaches function bodies)" {
  head -3 "$SCRIPT" | grep -q "set -Eeuo pipefail"
  grep -q "' ERR$" "$SCRIPT"
}

@test "trap release_lock is registered on EXIT" {
  grep -q 'trap release_lock EXIT' "$SCRIPT"
}

@test "max-turns is configured" {
  grep -q '\-\-max-turns' "$SCRIPT"
}

# === 自己改善ループの計測 (ADR-0006) ===

@test "daily-research.sh wires metrics collection non-fatally" {
  grep -q 'metrics-append' "$SCRIPT"
  grep -q 'report-lint' "$SCRIPT"
  grep -q 'review-age' "$SCRIPT"
  # 収集失敗が生成ジョブの成否 (FINAL_EXIT) を変えない non-fatal ガード
  grep -q 'WARN: metrics-append failed (non-fatal)' "$SCRIPT"
  # metrics-append は FINAL_EXIT 確定後 (exit 直前) に置かれている
  awk '/metrics-append/{m=NR} /^exit "\$FINAL_EXIT"/{e=NR} END{exit !(m && e && m<e)}' "$SCRIPT"
}

@test "metrics.jsonl and state/ are gitignored (personal data, public repo)" {
  grep -qx 'metrics.jsonl' "$PROJECT_DIR/.gitignore"
  grep -qx 'state/' "$PROJECT_DIR/.gitignore"
}

# === ADR-0017: window 輪番 / receipt gate / 呼2 = clarity + 原典照合 ===

@test "orchestrator logs every picked line and recomputes past themes per line" {
  grep -q 'PICKED_LIST' "$SCRIPT"
  grep -q 'Rotation pick: \$PICKED_LIST (ADR-0010/0017)' "$SCRIPT"
  grep -q "Today's lines: " "$SCRIPT"
  # past-themes はループ (for ROW in TRACK_ROWS) の内側でだけ呼ぶ
  awk '/^for ROW in "\$\{TRACK_ROWS\[@\]\}"; do/{inloop=1} /^done  # for ROW/{inloop=0}
       /python3 "\$DR_PY" past-themes/{ if (inloop) ok=1; else bad=1 }
       END{exit !(ok && !bad)}' "$SCRIPT"
}

@test "orchestrator hoists STATE_DIR and wires receipt / evidence / verify paths" {
  grep -q 'mkdir -p "\$STATE_DIR/runs"' "$SCRIPT"
  grep -q 'RECEIPT_PATH="\$STATE_DIR/runs/\${DATE}.json"' "$SCRIPT"
  grep -q 'VERIFY_PATH="\$STATE_DIR/runs/\${DATE}.verify.json"' "$SCRIPT"
  grep -q 'runs/\${DATE}.md' "$SCRIPT"
  grep -q 'brief.md' "$SCRIPT"
  grep -q 'pending.md' "$SCRIPT"
  grep -q 'receipt-read' "$SCRIPT"
  grep -q 'verify-read' "$SCRIPT"
  grep -q '"STATE"' "$SCRIPT"
  grep -q '"VERIFY"' "$SCRIPT"
  # run スコープ判定は find -newer (bash 3.2 の -nt は秒精度)
  grep -q -- '-newer "\$LOCK_DIR/pid"' "$SCRIPT"
}

@test "second call is verification: WebFetch allowed, WebSearch denied, note + verify.json only" {
  grep -q 'prompts/verification-protocol.md' "$SCRIPT"
  refute_grep -q 'clarity-review-protocol.md' "$SCRIPT"
  grep -qF -- '--allowedTools "Read,WebFetch,Edit(//${CLARITY_NOTE#/}),Edit(//${VERIFY_PATH#/})"' "$SCRIPT"
  grep -qF -- '--disallowedTools "$DISALLOWED_TOOLS,WebSearch"' "$SCRIPT"
  grep -qF -- '--max-turns 30' "$SCRIPT"
  grep -qF -- '--model "$VERIFY_MODEL"' "$SCRIPT"
  grep -qF 'CLAUDE_TIMEOUT=1200' "$SCRIPT"
  grep -q 'config-get "\$PROJECT_DIR/config.toml" verification.model sonnet' "$SCRIPT"
  grep -qF 'rm -f "$VERIFY_PATH"' "$SCRIPT"
}

@test "config.example.toml documents lines_per_day and [verification]" {
  grep -qE '^lines_per_day = [0-9]+' "$PROJECT_DIR/config.example.toml"
  grep -qx '\[verification\]' "$PROJECT_DIR/config.example.toml"
  grep -qE '^model = "sonnet"' "$PROJECT_DIR/config.example.toml"
  python3 "$PROJECT_DIR/scripts/lib/dr_pipeline.py" tracks "$PROJECT_DIR/config.example.toml" > /dev/null
}

@test "past_topics.example.json carries a question-granular entry" {
  python3 - "$PROJECT_DIR/past_topics.example.json" << 'PY'
import json, sys
t = json.load(open(sys.argv[1]))["topics"][0]
for k in ("date", "track", "title", "slug", "question", "answer_scope", "keywords", "summary", "opportunities"):
    assert k in t, k
PY
}


# === ecosystem line (mode = "ecosystem"、ADR-0018) の contract ===

ECO_PROTOCOL="$PROJECT_DIR/prompts/ecosystem-research-protocol.md"
ECO_TEMPLATE="$PROJECT_DIR/templates/report-template-ecosystem.md"

@test "both call-1 protocols carry the shared contract (states, receipt, evidence file, citation gate)" {
  local P
  for P in "$PROJECT_DIR/prompts/repo-research-protocol.md" "$ECO_PROTOCOL"; do
    grep -q '問いの形' "$P"
    grep -q '記事 / 短報 / 更新なし / 保留' "$P"
    grep -q '発見のノルマは無い' "$P"
    grep -q '文の形で分ける' "$P"
    grep -q '承認要求・「〜すべき」・手順の列挙は書かない' "$P"
    grep -q 'citation ゲート' "$P"
    grep -q '自己汚染ガード' "$P"
    grep -q 'last-attempt' "$P"
    grep -q '根拠ファイル' "$P"
    grep -q 'fetch_status' "$P"
    grep -qF '"status": "article|brief|quiet|hold"' "$P"
    grep -qF '"reason_code": "no_new_evidence|thin_material|fetch_failed|carry_over|unspecified"' "$P"
    grep -qF '{"date", "track", "title", "slug", "question", "answer_scope", "keywords": [], "summary", "opportunities"}' "$P"
    grep -q 'pending.md' "$P"
    grep -q '一文一命題' "$P"
    grep -q '## Line Research Complete' "$P"
    grep -q 'Bash は許可されていない' "$P"
  done
}

@test "ecosystem protocol: two exploration paths, change-based dedup, watchlist table, no repo context" {
  grep -q '経路 A' "$ECO_PROTOCOL"
  grep -q '経路 B' "$ECO_PROTOCOL"
  grep -q '両方実行する' "$ECO_PROTOCOL"
  grep -q '新発見に数えない' "$ECO_PROTOCOL"
  grep -q '前回報告後の変化' "$ECO_PROTOCOL"
  grep -q '初めて動くコードが公開された' "$ECO_PROTOCOL"
  grep -q '言い換えは再掲載しない' "$ECO_PROTOCOL"
  grep -qF '| 名前 | canonical URL | 種別 | 初出日 | last-attempt | last-seen | 最後に報告した意味のある変化 | 状態 |' "$ECO_PROTOCOL"
  grep -q 'active' "$ECO_PROTOCOL" && grep -q 'stalled' "$ECO_PROTOCOL" && grep -q 'archived' "$ECO_PROTOCOL"
  grep -q '掲載されていることを採用の根拠にしない' "$ECO_PROTOCOL"
  grep -q '公開日と出来事の日付を区別する' "$ECO_PROTOCOL"
  # repo 文脈・個人 harness を要求しない / 適用可能性を選定条件にしない
  refute_grep -q 'Step 3b' "$ECO_PROTOCOL"
  refute_grep -q 'repo の doctrine' "$ECO_PROTOCOL"
  refute_grep -q '選定後に読む候補' "$ECO_PROTOCOL"
  refute_grep -q 'この repo' "$ECO_PROTOCOL"
  grep -q '選定の条件にも本文の着地にも使わない' "$ECO_PROTOCOL"
  # プロトコルは mode の汎用品 — 特定エコシステムの固有名は config と state に置く
  refute_grep -qi 'jev' "$ECO_PROTOCOL"
  refute_grep -qi 'typesafe' "$ECO_PROTOCOL"
}

@test "repo protocol and default templates carry no ecosystem-line wording" {
  local F
  for F in "$PROJECT_DIR/prompts/repo-research-protocol.md" \
           "$PROJECT_DIR/templates/report-template.md" \
           "$PROJECT_DIR/templates/report-template-edge.md" \
           "$PROJECT_DIR/prompts/verification-protocol.md"; do
    refute_grep -qi 'jev' "$F"
    refute_grep -q 'watchlist' "$F"
    refute_grep -q 'エコシステム' "$F"
  done
}

@test "ecosystem template has kind/question frontmatter, no fixed body headings, fixed tail sections, no repo wording" {
  [ -f "$ECO_TEMPLATE" ]
  grep -q '^kind: article' "$ECO_TEMPLATE"
  grep -q '^question:' "$ECO_TEMPLATE"
  grep -q '固定見出しは置かない' "$ECO_TEMPLATE"
  grep -q '## 機会メモ' "$ECO_TEMPLATE"
  grep -q '## ソース' "$ECO_TEMPLATE"
  grep -q '失効日' "$ECO_TEMPLATE"
  grep -q '判定 source' "$ECO_TEMPLATE"
  # 固定見出しは末尾 2 節だけ (line 固有の固定節を足さない)
  [ "$(grep -c '^## ' "$ECO_TEMPLATE")" -eq 2 ]
  refute_grep -q 'この repo' "$ECO_TEMPLATE"
  refute_grep -qi 'jev' "$ECO_TEMPLATE"
}

@test "config.example.toml: the ecosystem example line matches the implemented schema" {
  local EX="$PROJECT_DIR/config.example.toml" PY="$PROJECT_DIR/scripts/lib/dr_pipeline.py"
  local rows brief
  rows=$(python3 "$PY" tracks "$EX")
  # repo line は 3 列目に target_repo、ecosystem line は 3 列目が空の 1 行
  printf '%s\n' "$rows" | grep -q "^example_line	example	/"
  printf '%s\n' "$rows" | grep -qx "example_ecosystem_line	example_ecosystem_line	"
  # daily = true の ecosystem 例は毎日、輪番 window の後ろに出る
  [ "$(python3 "$PY" rotation-pick "$EX" 2026-09-21 | tail -1 | cut -f1)" = "example_ecosystem_line" ]
  [ "$(python3 "$PY" rotation-pick "$EX" 2026-09-22 | tail -1 | cut -f1)" = "example_ecosystem_line" ]
  brief=$(python3 "$PY" line-brief "$EX" example_ecosystem_line)
  printf '%s\n' "$brief" | grep -q '^- mode: ecosystem'
  refute_grep -q '選定後に読む候補' <<< "$brief"
  [ "$(python3 "$PY" template-path "$EX" example_ecosystem_line)" = "templates/report-template-ecosystem.md" ]
  [ -f "$PROJECT_DIR/$(python3 "$PY" template-path "$EX" example_ecosystem_line)" ]
  # 公開テンプレートに個人パス・個人名を混ぜない
  refute_grep -q 'shimomoto' "$EX"
}
