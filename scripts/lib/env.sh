#!/usr/bin/env bash
# env.sh — 環境サニタイズと PATH 設定。
# daily-research.sh / check-auth.sh が source する。単独実行しない。

# 親の環境から来た API key は使わない。課金経路は config.toml の [billing] だけが決め、
# api mode のときに lib/billing.sh が env_file から key を読み直して export する
unset ANTHROPIC_API_KEY
# credential = "ant" のトークンと専用 config dir も billing.sh だけが入れる (親の環境の値で課金経路を変えない)
unset ANTHROPIC_AUTH_TOKEN CLAUDE_CONFIG_DIR ANTHROPIC_PROFILE
# CLAUDECODE が残っているとネストチェック・起動挙動が変わるため除去
unset CLAUDECODE 2>/dev/null || true
# 呼1 / 呼2 の effort は daily-research.sh が [effort] から --effort で渡す。CLAUDE_CODE_EFFORT_LEVEL は
# --effort より優先される (https://code.claude.com/docs/en/model-config.md の effort の優先順位、2026-11-08 確認)
# ので、親の環境 (対話 session の中から手で回した run など) の値を持ち込まない
unset CLAUDE_CODE_EFFORT_LEVEL

# launchd 環境は PATH が最小限。homebrew python3 (tomllib 必須, >=3.11) を /usr/bin より前に置く。
# 最終的な先頭は下の 2 つ (~/.local/bin、~/.claude/local) で、その後ろに homebrew が続く。
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
# Claude Code の旧インストール先も互換性のため維持する。
if [ -d "$HOME/.claude/local" ]; then
  export PATH="$HOME/.claude/local:$PATH"
fi
# 現行 native installer の配置先を優先する。
if [ -d "$HOME/.local/bin" ]; then
  export PATH="$HOME/.local/bin:$PATH"
fi
