#!/bin/bash
# Daily discovery edition: isolated research -> editorial -> validated publication.
# ADR-0016. Shell owns startup/auth/lock/notifications; discovery.py owns the run.
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
DR_PY="$LIB_DIR/dr_pipeline.py"
CONFIG="$PROJECT_DIR/config.toml"
DATE="$(date +%Y-%m-%d)"
PREVIEW=0
CLAUDE_OVERRIDE=""
usage() {
  echo 'Usage: daily-research.sh [--preview] [--date YYYY-MM-DD] [--config PATH] [--claude PATH]'
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --preview) PREVIEW=1; shift ;;
    --date|--config|--claude)
      [ "$#" -ge 2 ] || { usage >&2; exit 64; }
      case "$1" in
        --date) DATE="$2" ;;
        --config) CONFIG="$2" ;;
        --claude) CLAUDE_OVERRIDE="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
source "$LIB_DIR/env.sh"
if ! python3 -c 'import datetime,sys; d=datetime.date.fromisoformat(sys.argv[1]); assert d.isoformat()==sys.argv[1]' "$DATE" 2>/dev/null; then
  echo 'Invalid date: expected YYYY-MM-DD' >&2; exit 64
fi
if [ "$PREVIEW" = 0 ] && [ "$DATE" != "$(date +%Y-%m-%d)" ]; then
  echo 'Backdated runs require --preview; no production backfill.' >&2; exit 64
fi
[ -f "$CONFIG" ] || { echo "Config not found: $CONFIG" >&2; exit 64; }
if [ "$PREVIEW" = 1 ]; then
  LOG_DIR="$PROJECT_DIR/.notes/discovery-preview-logs"
  LOCK_DIR="$PROJECT_DIR/.daily-research-preview.lock"
else
  LOG_DIR="$PROJECT_DIR/logs"
  LOCK_DIR="$PROJECT_DIR/.daily-research.lock"
fi
LOG_FILE="$LOG_DIR/$DATE.log"
source "$LIB_DIR/log.sh"
source "$LIB_DIR/notify.sh"
source "$LIB_DIR/lock.sh"
source "$LIB_DIR/auth.sh"
log_init
trap release_lock EXIT
report_error() {
  local rc=$?
  log "ERROR: unexpected exit $rc at line $1"
  if [ "$PREVIEW" = 0 ]; then notify "リサーチが中断しました。ログを確認してください" 'Daily Research Error'; fi
  exit "$rc"
}
trap 'report_error "$LINENO"' ERR
if ! acquire_lock; then
  echo 'Another research run is active.' >&2
  exit 1
fi
CLAUDE_CMD="${CLAUDE_OVERRIDE:-$(command -v claude || true)}"
[ -n "$CLAUDE_CMD" ] && [ -x "$CLAUDE_CMD" ] || { echo 'Claude CLI not found.' >&2; exit 1; }
command -v timeout >/dev/null || { echo 'Install coreutils (timeout).' >&2; exit 1; }
log "=== Discovery start (preview=$PREVIEW) ==="
if ! real_auth_probe; then
  log 'ERROR: authentication failed'
  if [ "$PREVIEW" = 0 ]; then notify 'Claude の再認証が必要です' 'Daily Research Error'; fi
  exit 1
fi
ARGS=(run --config "$CONFIG" --date "$DATE" --claude "$CLAUDE_CMD")
if [ "$PREVIEW" = 1 ]; then ARGS+=(--preview); fi
RUN_EXIT=0
SUMMARY=$(python3 "$LIB_DIR/discovery.py" "${ARGS[@]}" 2>> "$LOG_FILE") || RUN_EXIT=$?
printf '%s\n' "$SUMMARY"
log "$SUMMARY"
if [ "$RUN_EXIT" != 0 ]; then
  if [ "$PREVIEW" = 0 ]; then notify '調査または編集が失敗しました。未完成原稿は保存していません' 'Daily Research Error'; fi
  exit "$RUN_EXIT"
fi
STATUS=$(printf '%s' "$SUMMARY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
if [ "$PREVIEW" = 1 ]; then
  log 'Preview complete; no publication, live history, notification or wiki ingest.'
  exit 0
fi
case "$STATUS" in
  published)
    notify '今朝の一冊が完成しました' 'Daily Research'
    VAULT_PATH=$(python3 "$DR_PY" vault-path "$CONFIG")
    INGEST="$VAULT_PATH/scripts/daily_wiki_ingest.sh"
    # Preserve the existing consumer. Run only after a new validated publication.
    # Preview, quiet, failure and duplicate runs cannot enter this branch.
    if [ -x "$INGEST" ]; then
      INGEST_EXIT=0
      bash "$INGEST" "$DATE" >> "$LOG_FILE" 2>&1 || INGEST_EXIT=$?
      if [ "$INGEST_EXIT" != 0 ]; then
        log "WARN: wiki ingest failed (non-fatal, exit $INGEST_EXIT)"
        notify '記事は完成しましたが、wiki取り込みが失敗しました' 'Daily Research'
      fi
    else
      log 'WARN: wiki ingest script unavailable; edition retained.'
    fi ;;
  quiet) notify '今日は届けたい発見がありませんでした。調査記録は保存しました' 'Daily Research' ;;
  skipped) log 'Already completed today; no repeated publication or ingest.' ;;
  *) log "ERROR: unexpected pipeline status: $STATUS"; exit 1 ;;
esac
log '=== Discovery complete ==='
