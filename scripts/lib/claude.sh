#!/usr/bin/env bash
# claude.sh — claude -p 実行ラッパーと終了状態の分類。source 専用。
# CLAUDE_CMD / DR_PY を呼び出し側で定義済みであること。

# claude -p の実行ラッパー
# CLAUDE_CMD は認証チェック時に絶対パスへ解決済み
# < /dev/null: MCP の stdio 通信とターミナル stdin の競合を防止
# CLAUDE_TIMEOUT: 0 以外を設定すると timeout コマンドで制限（秒）
run_claude() {
  if [ "${CLAUDE_TIMEOUT:-0}" -gt 0 ] 2>/dev/null; then
    timeout "$CLAUDE_TIMEOUT" "$CLAUDE_CMD" "$@" < /dev/null
  else
    "$CLAUDE_CMD" "$@" < /dev/null
  fi
}

# classify_exit <exit_code> <result_json>
# claude -p の終了コードと result JSON を 3 クラスのエラー分類に写像して echo する:
#   E_AUTH      : api_error_status==401 (再認証が必要。Sonnet フォールバックは無意味)
#   E_TRANSIENT : exit==124 (timeout。再試行で回復しうる)
#   E_FATAL     : is_error==true (401 以外) または exit!=0 (回復不能/要調査)
#   OK          : exit==0 かつ is_error 無し (成功)
# 401 ≠ timeout ≠ その他失敗 を分けるのが目的。exit コードだけでなく result JSON の
# is_error/api_error_status も見るため、「exit 0 だが is_error:true」(max-turns 空振り
# 等) を成功と誤認しない (ctl-003/ctl-007)。
classify_exit() {
  local code="${1:-0}" json="${2:-}"
  local fields acode aerr
  # error-fields は "api_error_status<TAB>is_error" を返す。api_error_status が空のとき
  # 先頭フィールドが空になるが、`IFS=$'\t' read` は TAB が IFS 空白扱いのため先頭の空を
  # 潰してしまう。パラメータ展開で TAB の前後を取り出し、空の先頭フィールドを保持する。
  fields=$(printf '%s' "$json" | python3 "$DR_PY" error-fields) || fields=""
  acode="${fields%%$'\t'*}"
  aerr="${fields#*$'\t'}"
  if [ "$acode" = "401" ]; then
    echo "E_AUTH"
  elif [ "$code" = "124" ]; then
    echo "E_TRANSIENT"
  elif [ "$aerr" = "true" ] || [ "$code" != "0" ]; then
    echo "E_FATAL"
  else
    echo "OK"
  fi
}
