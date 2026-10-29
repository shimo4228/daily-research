#!/bin/bash
set -euo pipefail

# Claude の認証状態チェック (手動実行用)。daily-research.sh と同じ経路で確かめる:
# config.toml の [billing] (lib/billing.sh) で課金経路を決め、lib/auth.sh の real_auth_probe で
# 実 API を叩く。api mode は env_file の ANTHROPIC_API_KEY、subscription mode は Max plan の OAuth。
# `claude --version` は認証切れでも成功するので認証検証に使わない。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck disable=SC2034  # DR_PY / DATE は source した lib で使用
DR_PY="$LIB_DIR/dr_pipeline.py"
# shellcheck disable=SC2034
DATE=$(date +%Y-%m-%d)

source "$LIB_DIR/env.sh"
source "$LIB_DIR/auth.sh"
source "$LIB_DIR/billing.sh"

if ! command -v claude &> /dev/null; then
  echo "ERROR: claude not found"
  osascript -e 'display notification "claude コマンドが見つかりません" with title "Auth Check"' 2>/dev/null || true
  exit 1
fi
# shellcheck disable=SC2034  # CLAUDE_CMD は source した lib/auth.sh で使用
CLAUDE_CMD=$(command -v claude)

if ! billing_load "$PROJECT_DIR/config.toml"; then
  echo "ERROR: $BILLING_ERROR"
  exit 1
fi
echo "Billing mode: $BILLING_MODE"

# 実 API を叩いて認証を検証する (api mode の probe 費用は支出台帳に記録する)
if real_auth_probe; then
  billing_record "$AUTH_PROBE_JSON" "_probe" "probe"
  echo "OK: Claude authentication is valid"
  if [ "$BILLING_MODE" = "api" ]; then
    billing_gate || true
    echo "API spend: today \$$SPEND_DAY / \$$BILLING_DAILY_CAP, month \$$SPEND_MONTH / \$$BILLING_MONTHLY_CAP"
  fi
  exit 0
fi
billing_record "$AUTH_PROBE_JSON" "_probe" "probe"
if [ "$BILLING_MODE" = "api" ]; then
  echo "WARN: Claude API rejected the request — $(auth_probe_reason)"
  echo "      Check ANTHROPIC_API_KEY in $BILLING_ENV_FILE and the credit balance on platform.claude.com"
  osascript -e 'display notification "Claude API の認証に失敗しました。key とクレジット残高を確認してください。" with title "Daily Research Auth Warning"' 2>/dev/null || true
else
  echo "WARN: Claude authentication expired — run 'claude' to re-authenticate"
  osascript -e 'display notification "Claude認証の更新が必要です。ターミナルで claude を起動してください。" with title "Daily Research Auth Warning"' 2>/dev/null || true
fi
exit 1
