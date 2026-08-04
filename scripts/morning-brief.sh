#!/bin/bash
set -euo pipefail

# morning-brief.sh — 毎朝 7:00 に当日リサーチノートの「今すぐ実行可能な手」を
# 決定論的に抽出し、Slack へ承認リクエストとして送る (ADR-0008)。
#
# 設計:
# - 抽出は純 shell/awk (LLM を挟まない)。vault notify.sh の設計注記どおり、
#   エスカレーション送信は untrusted テキストを読む LLM でなく呼び出し元シェルが行う。
# - Slack webhook は vault scripts/notify.sh の wiki_notify を source して再利用
#   (webhook 秘匿・macOS 通知フォールバック込み)。
# - 本 script の失敗はリサーチ生成の成否と独立 (5:00 の run には影響しない)。
# - 承認は一方向: 著者が次の Claude セッションで「<track> の手 N を実行」と指示する。
#   deploy 前 gate (各 repo の判断チェックリスト) はその時点で適用される。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
DR_PY="$LIB_DIR/dr_pipeline.py"

DATE=$(date +%Y-%m-%d)
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/$DATE.log"

source "$LIB_DIR/env.sh"
source "$LIB_DIR/log.sh"
log_init

log "=== Morning brief (7:00) ==="

REPORT_DIR=$(python3 "$DR_PY" report-dir "$PROJECT_DIR/config.toml" 2>> "$LOG_FILE") || REPORT_DIR=""
VAULT_PATH=$(python3 "$DR_PY" vault-path "$PROJECT_DIR/config.toml" 2>> "$LOG_FILE") || VAULT_PATH=""

if [ -z "$REPORT_DIR" ] || [ -z "$VAULT_PATH" ]; then
  log "ERROR: config.toml の vault_path/output_dir が未設定。brief を送れない"
  exit 1
fi

# Slack 送信ヘルパ (webhook 秘匿 + macOS フォールバック)。無ければ最後に手当て。
NOTIFY_SH="$VAULT_PATH/scripts/notify.sh"
if [ -f "$NOTIFY_SH" ]; then
  # shellcheck disable=SC1090
  source "$NOTIFY_SH"
else
  log "WARN: $NOTIFY_SH が見つからない — macOS 通知のみで送る"
  wiki_notify() {
    local nt="$1" nb="$2"
    nt="${nt//$'\n'/ }"; nt="${nt//\\/\\\\}"; nt="${nt//\"/\\\"}"
    nb="${nb//$'\n'/ }"; nb="${nb//\\/\\\\}"; nb="${nb//\"/\\\"}"
    osascript -e "display notification \"$nb\" with title \"$nt\"" 2>/dev/null || true
    return 1
  }
fi

# --- 当日ノートから「今すぐ実行可能な手」節を決定論抽出 ---
# 節境界: "## 今すぐ実行可能な手" 〜 次の "## "。1 ノートあたり 60 行に cap。
# 連続空行は 1 行に潰す (cat -s)。
extract_tactics() {
  awk '
    /^## 今すぐ実行可能な手/ { inside=1; next }
    /^## / { inside=0 }
    inside && count < 60 { print; count++ }
    inside && count == 60 { print "  (…以下略 — ノート本体を参照)"; count++ }
  ' "$1" | cat -s
}

# 既知 track 名 (filename の track 部は underscore を含みうるため最長一致で判定)
TRACK_NAMES=$(python3 "$DR_PY" tracks "$PROJECT_DIR/config.toml" 2>/dev/null | cut -f1 | sort -u) || TRACK_NAMES=""

BODY=""
NOTE_COUNT=0
TOTAL_ACTIONABLE=0

shopt -s nullglob
for f in "$REPORT_DIR/${DATE}_"*.md; do
  NOTE_COUNT=$((NOTE_COUNT + 1))
  name=$(basename "$f" .md)
  # filename = {date}_{track}_{slug}.md → track を抽出
  rest="${name#"${DATE}"_}"
  track=""
  for t in $TRACK_NAMES; do
    case "$rest" in "$t"_*|"$t") track="$t"; break ;; esac
  done
  [ -z "$track" ] && track="${rest%%_*}"

  # frontmatter の actionable: N (無ければ抽出節の「**手」行数で代替)
  n_act=$(sed -n '1,12p' "$f" | sed -n 's/^actionable:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
  tactics=$(extract_tactics "$f")
  if [ -z "$n_act" ]; then
    n_act=$(printf '%s\n' "$tactics" | grep -c '^\*\*手' || true)
  fi
  TOTAL_ACTIONABLE=$((TOTAL_ACTIONABLE + n_act))

  BODY="$BODY
━ ${track} (${n_act} 件) — ${name}.md
$tactics
"
done
shopt -u nullglob

if [ "$NOTE_COUNT" -eq 0 ]; then
  TITLE="Daily Research ${DATE} — ノートなし"
  BODY="本日のリサーチノートが vault にありません (5:00 の run が失敗した可能性)。logs/${DATE}.log を確認してください。"
elif [ "$TOTAL_ACTIONABLE" -eq 0 ]; then
  TITLE="Daily Research ${DATE} — 本日 actionable なし (${NOTE_COUNT} ノート)"
  BODY="全 line で actionable な手はありませんでした (証拠付き陰性 — 各ノートの「差分と失効チェック」参照)。
$BODY"
else
  TITLE="Daily Research ${DATE} — 実装プラン承認リクエスト (${TOTAL_ACTIONABLE} 件)"
  BODY="今朝のリサーチから以下の手が提案されています。
$BODY
──
承認: 次の Claude セッションで「<track> の手 N を実行」と指示してください。
deploy 前 gate (各 repo の判断チェックリスト) はその時点で適用されます。手には失効条件があります — 放置は否認と同じです。"
fi

if wiki_notify "$TITLE" "$BODY" >> "$LOG_FILE" 2>&1; then
  log "Morning brief sent to Slack (${NOTE_COUNT} notes, ${TOTAL_ACTIONABLE} tactics)"
else
  log "WARN: Slack 送信失敗 — macOS 通知にフォールバック済み (${NOTE_COUNT} notes)"
fi
