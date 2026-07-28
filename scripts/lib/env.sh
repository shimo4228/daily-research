#!/usr/bin/env bash
# env.sh — 環境サニタイズと PATH 設定。
# daily-research.sh / bootstrap-graph.sh が source する。単独実行しない。

# APIキーが設定されていると従量課金になるため確実に除去
unset ANTHROPIC_API_KEY
# CLAUDECODE が残っているとネストチェック・起動挙動が変わるため除去
unset CLAUDECODE 2>/dev/null || true

# launchd 環境は PATH が最小限。homebrew python3 (tomllib 必須, >=3.11) を先頭に明示設定。
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
# Claude Code の旧インストール先も互換性のため維持する。
if [ -d "$HOME/.claude/local" ]; then
  export PATH="$HOME/.claude/local:$PATH"
fi
# 現行 native installer の配置先を優先する。
if [ -d "$HOME/.local/bin" ]; then
  export PATH="$HOME/.local/bin:$PATH"
fi
