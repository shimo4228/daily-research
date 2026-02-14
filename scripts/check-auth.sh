#!/bin/bash
set -euo pipefail

# Claude Code OAuth認証状態チェック

if ! command -v claude &> /dev/null; then
  echo "ERROR: claude not found"
  osascript -e 'display notification "claude コマンドが見つかりません" with title "Auth Check"' 2>/dev/null || true
  exit 1
fi

# claude --version が正常に返ることで認証状態を間接確認
if claude --version > /dev/null 2>&1; then
  echo "OK: Claude authentication is valid"
  exit 0
else
  echo "WARN: Claude authentication may need refresh"
  osascript -e 'display notification "Claude認証の更新が必要です。ターミナルで claude を起動してください。" with title "Daily Research Auth Warning"' 2>/dev/null || true
  exit 1
fi
