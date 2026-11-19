#!/usr/bin/env bash
# shellcheck disable=SC2034  # BILLING_* / BUDGET_FLAGS / SPEND_* は source する側が読む出力変数
# billing.sh — claude -p の課金経路 (Max plan の OAuth / Claude API の key) と API 支出の上限。source 専用。
# 呼び出し側で DR_PY / PROJECT_DIR / DATE を定義済みであること。
#
# 契約の正本は dr_pipeline.py の [billing] 節 (BILLING_MODES / _billing)。
# - mode = "subscription": env.sh が ANTHROPIC_API_KEY を unset した状態のまま (OAuth)
# - mode = "api": 資格情報の出どころは credential が決める。値はログ・通知・引数に載せない
#   (export した環境変数だけが claude に届く)
#   - credential = "env_file": env_file から ANTHROPIC_API_KEY を読んで export する
#   - credential = "ant": Console の `ant auth login` のアクセストークン (寿命 8 時間、ant が更新する) を
#     billing_refresh_token が ANTHROPIC_AUTH_TOKEN に入れる (auth probe は billing_load で取った値、以後は run_claude が
#     呼び出しごとに取り直す)。CLAUDE_CONFIG_DIR を claude.ai ログインを持たない専用 dir
#     (BILLING_CLAUDE_CONFIG_DIR) にする — 通常の config dir では保存済みの claude.ai (Max) ログインが優先され、
#     偽のトークンでも Max で成功した (2026-11-19 実測、plan docs/plans/keyless-console-login.md)。
#     Claude Code は ANTHROPIC_PROFILE の profile を読まなかったので、トークンを直接渡す
# 支出は 1 呼び出しごとに state/api-spend.jsonl へ追記し、line を始める前に月・日の残額を見る。
# 予約額 (BILLING_RESERVE = 1 line 分、BILLING_AUDIT_RESERVE = 呼3 の 2 段分) は billing-config が計算する。

SPEND_LEDGER="${SPEND_LEDGER:-$PROJECT_DIR/state/api-spend.jsonl}"
BILLING_LEDGER_BROKEN=0   # 台帳への追記に失敗した — 以後は上限を判定できないので gate が止める

# log() があれば (daily-research.sh) そこへ、無ければ (check-auth.sh) stderr へ
_billing_log() {
  if declare -F log >/dev/null 2>&1; then log "$1"; else echo "$1" >&2; fi
}

# billing_load <config_path>: BILLING_MODE ほかを設定し、api なら資格情報を export する。
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
    BILLING_CALL1_MAX BILLING_CALL2_MAX BILLING_AUDIT_MAX BILLING_AUDIT_CONFIRM_MAX \
    BILLING_RESERVE BILLING_AUDIT_RESERVE BILLING_CREDENTIAL BILLING_ANT_PROFILE <<< "$tsv"
  if [ "$BILLING_MODE" != "api" ]; then
    BILLING_CREDENTIAL=""
    return 0
  fi
  if [ "$BILLING_CREDENTIAL" = "ant" ]; then
    BILLING_ENV_FILE=""
    BILLING_CLAUDE_CONFIG_DIR="${BILLING_CLAUDE_CONFIG_DIR:-$PROJECT_DIR/state/claude-config}"
    if ! mkdir -p "$BILLING_CLAUDE_CONFIG_DIR" 2>/dev/null; then
      BILLING_ERROR="claude の専用 config dir を作れない: $BILLING_CLAUDE_CONFIG_DIR"
      return 1
    fi
    export CLAUDE_CONFIG_DIR="$BILLING_CLAUDE_CONFIG_DIR"
    if ! billing_refresh_token; then
      BILLING_ERROR="ant のトークンを取れない (profile $BILLING_ANT_PROFILE)。\`ant auth login --profile $BILLING_ANT_PROFILE\` でログインし直す"
      return 1
    fi
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

# billing_refresh_token: credential = "ant" のとき ant から今のアクセストークンを取り ANTHROPIC_AUTH_TOKEN に
# export する (期限切れ間近なら ant が更新してから出す)。run_claude が呼び出しごとに呼ぶ。取れなければ 1 を返し、
# 前の値を残す (まだ有効なら使え、切れていれば claude が 401 を返して E_AUTH になる)。他の credential では何もしない
billing_refresh_token() {
  [ "${BILLING_CREDENTIAL:-}" = "ant" ] || return 0
  local tok
  tok=$("${ANT_CMD:-ant}" --profile "$BILLING_ANT_PROFILE" auth print-credentials --access-token < /dev/null 2>/dev/null) || tok=""
  tok=$(printf '%s' "$tok" | tr -d '[:space:]')
  if [ -z "$tok" ]; then
    _billing_log "WARN: ant auth print-credentials returned no token (profile $BILLING_ANT_PROFILE)"
    return 1
  fi
  printf -v ANTHROPIC_AUTH_TOKEN '%s' "$tok"
  export ANTHROPIC_AUTH_TOKEN
  return 0
}

# billing_credential_hint: api mode の認証失敗のときに運用者へ出す「何を確かめるか」の 1 文 (通知・check-auth 用)
billing_credential_hint() {
  if [ "${BILLING_CREDENTIAL:-}" = "ant" ]; then
    echo "ant のログイン (profile $BILLING_ANT_PROFILE) が切れていないか確かめ、必要なら ant auth login --profile $BILLING_ANT_PROFILE でログインし直してください"
  else
    echo "$BILLING_ENV_FILE の API key (期限切れ・失効) とクレジット残高を確かめてください"
  fi
}

# budget_flags <1|2|audit|audit_confirm>: api mode のとき呼び出し 1 回の上限フラグを BUDGET_FLAGS 配列に入れる
# (1 = 呼1、2 = 呼2、audit / audit_confirm = 呼3 の第 1 段 / 第 2 段の 1 回)。
budget_flags() {
  BUDGET_FLAGS=()
  if [ "${BILLING_MODE:-subscription}" = "api" ]; then
    case "$1" in
      1) BUDGET_FLAGS=(--max-budget-usd "$BILLING_CALL1_MAX") ;;
      audit) BUDGET_FLAGS=(--max-budget-usd "$BILLING_AUDIT_MAX") ;;
      audit_confirm) BUDGET_FLAGS=(--max-budget-usd "$BILLING_AUDIT_CONFIRM_MAX") ;;
      *) BUDGET_FLAGS=(--max-budget-usd "$BILLING_CALL2_MAX") ;;
    esac
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

# billing_gate [reserve]: api mode で月・日の残額が reserve (既定 BILLING_RESERVE = 1 line 分) を満たせば 0、
# 支出の上限 (残額が reserve に満たない) で止めるなら 1、上限を確かめられずに止めるなら 2。line の前は既定で、
# 呼3 の前は BILLING_AUDIT_RESERVE / 第 2 段の 1 回分で呼ぶ。SPEND_MONTH / SPEND_DAY に今月・今日の累計を
# 入れる (2 のときは "?")。2 の理由 (台帳が書けなかった・読めない行がある・mktemp や gate 自体の失敗) は
# ここで ERROR として log してから返す — 呼ぶ側は 1 と 2 で log と通知の文言を分け、上限に達していない日に
# 「上限に達した」と言わない。spend-gate の rc 1 は出力が stop で始まるときだけ上限 (python の未捕捉例外も rc 1)。
billing_gate() {
  local out err rc=0
  SPEND_MONTH="?"; SPEND_DAY="?"
  [ "${BILLING_MODE:-subscription}" = "api" ] || return 0
  if [ "$BILLING_LEDGER_BROKEN" = "1" ]; then
    _billing_log "ERROR: API spend ledger could not be written earlier in this run — cannot check the caps"
    return 2
  fi
  if ! err=$(mktemp); then
    _billing_log "ERROR: API spend gate could not create a temp file (mktemp failed) — cannot check the caps"
    return 2
  fi
  out=$(python3 "$DR_PY" spend-gate "$SPEND_LEDGER" "$DATE" "$BILLING_MONTHLY_CAP" \
    "$BILLING_DAILY_CAP" "${1:-$BILLING_RESERVE}" 2>"$err") || rc=$?
  if [ "$rc" = "0" ] || { [ "$rc" = "1" ] && [ "${out%%$'\t'*}" = "stop" ]; }; then
    IFS=$'\t' read -r _ SPEND_MONTH SPEND_DAY <<< "$out"
  else
    _billing_log "ERROR: API spend gate failed (rc $rc): $(cat "$err") — cannot check the caps"
    rc=2
  fi
  rm -f "$err"
  return "$rc"
}
