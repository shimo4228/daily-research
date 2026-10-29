#!/usr/bin/env bash
# claude.sh — claude -p 実行ラッパーと終了状態の分類。source 専用。
# CLAUDE_CMD / DR_PY を呼び出し側で定義済みであること。

# claude -p の実行ラッパー
# CLAUDE_CMD は認証チェック時に絶対パスへ解決済み
# < /dev/null: MCP の stdio 通信とターミナル stdin の競合を防止
# CLAUDE_TIMEOUT: 0 以外を設定すると timeout コマンドで制限（秒）
run_claude() {
  if [ "${CLAUDE_TIMEOUT:-0}" -gt 0 ] 2>/dev/null; then
    # -k 60: SIGTERM を無視する node / MCP 子プロセスが lock を握ったまま永久待機し、
    # 翌朝以降の run を全部 "Another instance is running" で潰す事故を防ぐ (2026-08-22 review)
    timeout -k 60 "$CLAUDE_TIMEOUT" "$CLAUDE_CMD" "$@" < /dev/null
  else
    "$CLAUDE_CMD" "$@" < /dev/null
  fi
}

# classify_exit <exit_code> <result_json>
# claude -p の終了コードと result JSON をエラー分類に写像して echo する:
#   E_AUTH      : api_error_status==401 (OAuth 切れ・API key の拒否)、api mode では 403 も。再試行は無意味
#   E_BILLING   : api mode の 429 / 402 / クレジット残高不足 (再試行せず残 line を止める — policy signal)
#   E_BUDGET    : 呼び出し 1 回の --max-budget-usd に到達 (再試行しない。費用の上限そのもの)
#   E_TRANSIENT : exit==124 (timeout。再試行で回復しうる)
#   E_FATAL     : is_error==true (401 以外) または exit!=0 (回復不能/要調査)
#   OK          : exit==0 かつ is_error 無し (成功)
# 401 ≠ timeout ≠ その他失敗 を分けるのが目的。exit コードだけでなく result JSON の
# is_error/api_error_status も見るため、「exit 0 だが is_error:true」(max-turns 空振り
# 等) を成功と誤認しない (ctl-003/ctl-007)。
classify_exit() {
  local code="${1:-0}" json="${2:-}"
  local fields acode aerr akind _rest
  # error-fields は "api_error_status<TAB>is_error<TAB>kind" を返す。空のフィールドがありうるが、
  # `IFS=$'\t' read` は TAB が IFS 空白扱いのため連続 TAB を潰してしまう。パラメータ展開で
  # 切り出し、空のフィールドを保持する。
  fields=$(printf '%s' "$json" | python3 "$DR_PY" error-fields) || fields=""
  acode="${fields%%$'\t'*}"; _rest="${fields#*$'\t'}"
  aerr="${_rest%%$'\t'*}"; akind="${_rest#*$'\t'}"
  [ "$akind" = "$_rest" ] && akind=""  # TAB が 2 個無い旧形式 (想定外の入力) への保険
  # 403 と課金系 (429 / クレジット) を止める扱いにするのは api mode だけ。subscription mode は
  # 従来どおり 401 だけが E_AUTH、それ以外の失敗は E_FATAL (1 回リトライ)。
  if [ "${BILLING_MODE:-subscription}" != "api" ]; then
    akind=""
    [ "$acode" = "403" ] && acode=""
  fi
  if [ "$acode" = "401" ] || [ "$acode" = "403" ]; then
    echo "E_AUTH"
  elif [ "$akind" = "billing" ]; then
    echo "E_BILLING"
  elif [ "$akind" = "budget" ]; then
    echo "E_BUDGET"
  elif [ "$code" = "124" ]; then
    echo "E_TRANSIENT"
  elif [ "$aerr" = "true" ] || [ "$code" != "0" ]; then
    echo "E_FATAL"
  else
    echo "OK"
  fi
}
