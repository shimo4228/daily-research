#!/usr/bin/env bash
# auth.sh — Claude Code OAuth の実 auth probe (唯一の正本)。source 専用。
# CLAUDE_CMD (claude の絶対パス) と DR_PY を呼び出し側で定義済みであること。
#
# `claude --version` は OAuth 期限切れでも成功する formalized check なので、認証検証に
# 使えない (2026-06-21 の本番はこれを通過した直後に実 API で 401)。real_auth_probe は
# 安価な Haiku 呼び出しで実 API を叩き、is_error / api_error_status を検査する。
#
# daily-research.sh / check-auth.sh / bootstrap-graph.sh の 3 エントリポイントが
# これを共有し、形骸化した重複チェックを排除する。
# run_claude には依存しない (auth.sh は run_claude を持たない check-auth.sh 等からも
# source されるため、CLAUDE_CMD を直接叩く)。

# real_auth_probe: OAuth 有効なら 0、401/is_error を検出したら 1 を返す。
# probe 自体が transient/parse 失敗した場合は 0 (本編に進ませ、実呼び出しで顕在化させる)。
real_auth_probe() {
  local probe_json code err
  if command -v timeout >/dev/null 2>&1; then
    probe_json=$(timeout 60 "$CLAUDE_CMD" -p ok --max-turns 1 --model haiku \
      --output-format json < /dev/null 2>/dev/null) || true
  else
    probe_json=$("$CLAUDE_CMD" -p ok --max-turns 1 --model haiku \
      --output-format json < /dev/null 2>/dev/null) || true
  fi
  IFS=$'\t' read -r code err < <(printf '%s' "$probe_json" | python3 "$DR_PY" error-fields) || true
  if [ "$code" = "401" ] || [ "$err" = "true" ]; then
    return 1
  fi
  return 0
}
