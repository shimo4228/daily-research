#!/usr/bin/env bash
# shellcheck disable=SC2034  # BILLING_* / BUDGET_FLAGS / SPEND_* は source する側が読む出力変数
# billing.sh — claude -p の課金経路 (Max plan の OAuth / Claude API の key) と API 支出の上限。source 専用。
# 呼び出し側で DR_PY / PROJECT_DIR / DATE を定義済みであること。
#
# 契約の正本は dr_pipeline.py の [billing] 節 (BILLING_MODES / _billing)。
# - mode = "subscription": env.sh が ANTHROPIC_API_KEY を unset した状態のまま (OAuth)
# - mode = "api": env_file から ANTHROPIC_API_KEY を読んで export する。key の値はログ・通知・
#   引数に載せない (export した環境変数だけが claude に届く)
# 支出は 1 呼び出しごとに state/api-spend.jsonl へ追記し、line を始める前に月・日の残額を見る。

SPEND_LEDGER="${SPEND_LEDGER:-$PROJECT_DIR/state/api-spend.jsonl}"
BILLING_LEDGER_BROKEN=0   # 台帳への追記に失敗した — 以後は上限を判定できないので gate が止める

# log() があれば (daily-research.sh) そこへ、無ければ (check-auth.sh) stderr へ
_billing_log() {
  if declare -F log >/dev/null 2>&1; then log "$1"; else echo "$1" >&2; fi
}

# billing_load <config_path>: BILLING_MODE ほかを設定し、api なら key を export する。
# 失敗は BILLING_ERROR に理由を入れて 1 を返す (呼ぶ側が log / notify / exit する)。
billing_load() {
  local tsv key
  BILLING_ERROR=""
  if ! tsv=$(python3 "$DR_PY" billing-config "$1" 2>/dev/null); then
    # 失敗時だけ stderr を取り直す (成功時の stdout に stderr を混ぜると TSV が壊れる)
    BILLING_ERROR="[billing] の設定が不正: $(python3 "$DR_PY" billing-config "$1" 2>&1 >/dev/null)"
    return 1
  fi
  IFS=$'\t' read -r BILLING_MODE BILLING_ENV_FILE BILLING_MONTHLY_CAP BILLING_DAILY_CAP \
    BILLING_CALL1_MAX BILLING_CALL2_MAX <<< "$tsv"
  BILLING_RESERVE=$(python3 -c 'import sys; print(float(sys.argv[1]) + float(sys.argv[2]))' \
    "$BILLING_CALL1_MAX" "$BILLING_CALL2_MAX")
  if [ "$BILLING_MODE" != "api" ]; then
    return 0
  fi
  if ! key=$(python3 "$DR_PY" env-key "$BILLING_ENV_FILE" 2>/dev/null); then
    BILLING_ERROR="ANTHROPIC_API_KEY が $BILLING_ENV_FILE に無い (または読めない)"
    return 1
  fi
  printf -v ANTHROPIC_API_KEY '%s' "$key"
  export ANTHROPIC_API_KEY
  return 0
}

# budget_flags <1|2>: api mode のとき呼び出し 1 回の上限フラグを BUDGET_FLAGS 配列に入れる。
budget_flags() {
  BUDGET_FLAGS=()
  if [ "${BILLING_MODE:-subscription}" = "api" ]; then
    if [ "$1" = "1" ]; then
      BUDGET_FLAGS=(--max-budget-usd "$BILLING_CALL1_MAX")
    else
      BUDGET_FLAGS=(--max-budget-usd "$BILLING_CALL2_MAX")
    fi
  fi
}

# billing_record <json> <line> <call> [fallback_usd]: api mode の呼び出し費用を台帳に追記する。
# JSON に費用が無い (timeout で kill された等) ときは fallback_usd (その呼び出しの上限額) を
# 見積もりとして記録する。追記に失敗したら log して BILLING_LEDGER_BROKEN=1 — 以後の
# billing_gate が止める (数えられない支出があるまま次の line を始めない)。常に 0 を返す。
billing_record() {
  [ "${BILLING_MODE:-subscription}" = "api" ] || return 0
  local err
  if ! err=$(printf '%s' "$1" | python3 "$DR_PY" spend-add "$SPEND_LEDGER" "$DATE" "$2" "$3" "${4:-0}" 2>&1 >/dev/null); then
    BILLING_LEDGER_BROKEN=1
    _billing_log "ERROR: could not record API spend for $2/$3 in $SPEND_LEDGER: ${err:-no stderr}"
  fi
  return 0
}

# billing_gate: api mode で次の line を始めてよいなら 0、止めるなら 1。
# SPEND_MONTH / SPEND_DAY に今月・今日の累計を入れる。上限に届いた以外の理由で止めるとき
# (台帳が書けなかった・読めない行がある・gate 自体の失敗) は、その理由を log してから 1 を返す
# — 呼ぶ側の「上限に達した」ログと取り違えないため。
billing_gate() {
  local out err rc=0
  SPEND_MONTH="?"; SPEND_DAY="?"
  [ "${BILLING_MODE:-subscription}" = "api" ] || return 0
  if [ "$BILLING_LEDGER_BROKEN" = "1" ]; then
    _billing_log "ERROR: API spend ledger could not be written earlier in this run — cannot check the caps"
    return 1
  fi
  err=$(mktemp) || return 1
  out=$(python3 "$DR_PY" spend-gate "$SPEND_LEDGER" "$DATE" "$BILLING_MONTHLY_CAP" \
    "$BILLING_DAILY_CAP" "$BILLING_RESERVE" 2>"$err") || rc=$?
  if [ "$rc" = "0" ] || [ "$rc" = "1" ]; then
    IFS=$'\t' read -r _ SPEND_MONTH SPEND_DAY <<< "$out"
  else
    _billing_log "ERROR: API spend gate failed (rc $rc): $(cat "$err") — cannot check the caps"
  fi
  rm -f "$err"
  [ "$rc" = "0" ]
}
