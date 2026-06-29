#!/usr/bin/env bash
# notify.sh — macOS 通知。source 専用。
# osascript が無い環境 (headless / CI) では静かに no-op (ctl-011)。

notify() {
  command -v osascript >/dev/null 2>&1 || return 0
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
  osascript -e "display notification \"$body\" with title \"$title\"" 2>/dev/null || true
}
