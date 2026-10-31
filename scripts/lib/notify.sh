#!/usr/bin/env bash
# notify.sh — macOS 通知。source 専用。
# osascript が無い環境 (headless / CI) では no-op (ctl-011) — ただし log には残す。
# notify は無人 run の唯一の push 経路なので、配送失敗を自分で飲み込まない: 成否を
# 必ず log に 1 行残す (2026-08-22 review — TCC reset / Focus / Aqua session 不在で
# 数日間「通知が出ない」状態が検出不能だった)。log() が未定義なら stderr へ。
_notify_log() {
  if declare -F log >/dev/null 2>&1; then log "$1"; else echo "$1" >&2; fi
}

notify() {
  if ! command -v osascript >/dev/null 2>&1; then
    _notify_log "WARN: notify skipped (osascript not found): $2"
    return 0
  fi
  local body="$1"
  local title="$2"
  # AppleScript インジェクション防止: まず改行を空白へ (改行は -e "..." 文を分断し
  # 多文 injection を許す)、次にバックスラッシュ → ダブルクォートの順でエスケープ
  body="${body//$'\n'/ }"
  title="${title//$'\n'/ }"
  body="${body//\\/\\\\}"
  body="${body//\"/\\\"}"
  title="${title//\\/\\\\}"
  title="${title//\"/\\\"}"
  local err
  if err=$(osascript -e "display notification \"$body\" with title \"$title\"" 2>&1 >/dev/null); then
    _notify_log "notify sent: $title"
  else
    _notify_log "WARN: notify failed (${err:-no stderr}): $title"
  fi
  return 0
}

# report_unexpected_exit <rc> <lineno> <command>: daily-research.sh の ERR trap の本体。
# set -E の ERR trap は $(…) のサブシェルにも継承され、サブシェルからは外側の `|| X` /
# `if !` が見えないので、親が処理する失敗でも発火する (2026-10-29、report-lint の exit 2 で
# 誤った「予期せず中断」通知)。記録・通知は親シェル (BASH_SUBSHELL=0) でだけ行う。
# `x=$(f)` や末尾が単純コマンドの pipeline が失敗して親が落ちるときは、親側の ERR trap が
# 発火する。bash 3.2 では裸の `( f )` と `… | while …; done` (末尾が複合コマンド) の失敗は
# 親の ERR trap を通らずに無言で落ちる — orchestrator ではこの 2 形を使わない。
report_unexpected_exit() {
  [ "${BASH_SUBSHELL:-0}" = "0" ] || return 0
  _notify_log "ERROR: unexpected exit $1 at line $2: $3"
  notify "リサーチが予期せず中断しました (line $2)" "Daily Research Error"
}
