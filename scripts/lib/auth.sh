#!/usr/bin/env bash
# auth.sh — Claude Code の実 auth probe (OAuth / API key 共通、唯一の正本)。source 専用。
# CLAUDE_CMD (claude の絶対パス) と DR_PY を呼び出し側で定義済みであること。
#
# `claude --version` は OAuth 期限切れでも成功する formalized check なので、認証検証に
# 使えない (2026-06-21 の本番はこれを通過した直後に実 API で 401)。real_auth_probe は
# 安価な Haiku 呼び出しで実 API を叩き、is_error / api_error_status を検査する。
#
# daily-research.sh / check-auth.sh の 2 エントリポイントが
# これを共有し、形骸化した重複チェックを排除する。
# run_claude には依存しない (auth.sh は run_claude を持たない check-auth.sh 等からも
# source されるため、CLAUDE_CMD を直接叩く)。

# real_auth_probe: 認証が通れば 0、401 か is_error (api mode では 429・クレジット切れも含む) なら 1 を返す。
# 認証の経路は環境で決まる — ANTHROPIC_API_KEY があれば API key (lib/billing.sh の api mode)、
# 無ければ Max plan の OAuth。API key の拒否・クレジット切れ・429 も is_error で 1 になる。
# probe 自体が transient/parse 失敗した場合は 0 (本編に進ませ、実呼び出しで顕在化させる)。
# AUTH_PROBE_JSON に probe の result JSON を残す (api mode の支出台帳と失敗理由のログ用)。
real_auth_probe() {
  local fields code err
  AUTH_PROBE_JSON=""
  if command -v timeout >/dev/null 2>&1; then
    AUTH_PROBE_JSON=$(timeout 60 "$CLAUDE_CMD" -p ok --max-turns 1 --model haiku \
      --output-format json --no-session-persistence < /dev/null 2>/dev/null) || true
  else
    AUTH_PROBE_JSON=$("$CLAUDE_CMD" -p ok --max-turns 1 --model haiku \
      --output-format json --no-session-persistence < /dev/null 2>/dev/null) || true
  fi
  # error-fields の "api_error_status<TAB>is_error<TAB>kind" から先頭 2 つを取り出す。
  # api_error_status が空でも先頭フィールドを保持するためパラメータ展開を使う
  # (TAB は IFS 空白で read が潰すため)。
  fields=$(printf '%s' "$AUTH_PROBE_JSON" | python3 "$DR_PY" error-fields) || fields=""
  code="${fields%%$'\t'*}"
  err="${fields#*$'\t'}"; err="${err%%$'\t'*}"
  if [ "$code" = "401" ] || [ "$err" = "true" ]; then
    return 1
  fi
  return 0
}

# auth_probe_reason: 直前の probe の失敗理由を 1 行で出力する (key の値は含まない)。
auth_probe_reason() {
  printf '%s' "$AUTH_PROBE_JSON" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "null") or {}
    print(f"status={d.get(\"api_error_status\")} result={str(d.get(\"result\") or \"\")[:200]}")
except Exception:
    print("no parseable probe output")
'
}
