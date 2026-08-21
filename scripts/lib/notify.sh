#!/usr/bin/env bash
# notify.sh — macOS 通知。source 専用。
# osascript が無い環境 (headless / CI) では no-op (ctl-011) — ただし log には残す。
# notify は無人 run の唯一の push 経路なので、配送失敗を自分で飲み込まない: 成否を
# 必ず log に 1 行残す (2026-08-22 review — TCC reset / Focus / Aqua session 不在で
# 数日間「通知が出ない」状態が検出不能だった)。log() が未定義なら stderr へ。
_notify_log() {
  if declare -F log >/dev/null 2>&1; then log "$1"; else echo "$1" >&2; fi
}

notify() {
  if ! command -v osascript >/dev/null 2>&1; then
    _notify_log "WARN: notify skipped (osascript not found): $2"
    return 0
  fi
  local body="$1"
  local title="$2"
  # AppleScript インジェクション防止: まず改行を空白へ (改行は -e "..." 文を分断し
  # 多文 injection を許す)、次にバックスラッシュ → ダブルクォートの順でエスケープ
  body="${body//$'\n'/ }"
  title="${title//$'\n'/ }"
  body="${body//\\/\\\\}"
  body="${body//\"/\\\"}"
  title="${title//\\/\\\\}"
  title="${title//\"/\\\"}"
  local err
  if err=$(osascript -e "display notification \"$body\" with title \"$title\"" 2>&1 >/dev/null); then
    _notify_log "notify sent: $title"
  else
    _notify_log "WARN: notify failed (${err:-no stderr}): $title"
  fi
  return 0
}
