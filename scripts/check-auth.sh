#!/bin/bash
set -euo pipefail

# Claude Code OAuth 認証状態チェック (手動実行用)。
# daily-research.sh と同じ lib/auth.sh の real_auth_probe を使う = 唯一の正本。
# 旧実装は `claude --version` で「間接確認」していたが、--version は OAuth 期限切れでも
# 成功する formalized check のため認証検証になっていなかった (本 flow に未配線でもあった)。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck disable=SC2034  # DR_PY は source した lib/auth.sh で使用
DR_PY="$LIB_DIR/dr_pipeline.py"

source "$LIB_DIR/env.sh"
source "$LIB_DIR/auth.sh"

if ! command -v claude &> /dev/null; then
  echo "ERROR: claude not found"
  osascript -e 'display notification "claude コマンドが見つかりません" with title "Auth Check"' 2>/dev/null || true
  exit 1
fi
# shellcheck disable=SC2034  # CLAUDE_CMD は source した lib/auth.sh で使用
CLAUDE_CMD=$(command -v claude)

# 実 API を叩いて OAuth を検証する
if real_auth_probe; then
  echo "OK: Claude authentication is valid"
  exit 0
else
  echo "WARN: Claude authentication expired — run 'claude' to re-authenticate"
  osascript -e 'display notification "Claude認証の更新が必要です。ターミナルで claude を起動してください。" with title "Daily Research Auth Warning"' 2>/dev/null || true
  exit 1
fi
