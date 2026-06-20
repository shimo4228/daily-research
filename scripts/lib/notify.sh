#!/usr/bin/env bash
# notify.sh — macOS 通知。source 専用。
# osascript が無い環境 (headless / CI) では静かに no-op (ctl-011)。

notify() {
  command -v osascript >/dev/null 2>&1 || return 0
  local body="$1"
  local title="$2"
  # AppleScript インジェクション防止: バックスラッシュ → ダブルクォートの順でエスケープ
  body="${body//\\/\\\\}"
  body="${body//\"/\\\"}"
  title="${title//\\/\\\\}"
  title="${title//\"/\\\"}"
  osascript -e "display notification \"$body\" with title \"$title\"" 2>/dev/null || true
}
