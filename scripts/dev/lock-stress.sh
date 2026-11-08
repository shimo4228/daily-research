#!/bin/bash
# lock-stress.sh — scripts/lib/lock.sh の二重取得を数える stress (dev 専用。Claude を呼ばない)。
#
# 使い方:
#   scripts/dev/lock-stress.sh [--lock-sh PATH] [--procs N] [--trials T] [--widen SEC] [--state none|stale|both]
#   trial ごとに N 本の取得者を barrier で揃えて同時に acquire_lock させ、0 を返した取得者 (winner) を数える。
#   winner は全員の試行が終わるまで lock を握り続けるので、winner が 2 本以上の trial は二重取得そのもの。
#   --lock-sh  試す lock.sh (既定はこの repo の scripts/lib/lock.sh。旧版は git show で写して渡す)
#   --state    none = lock が無い状態から / stale = 死んだ PID を持つ lock dir から / both = 両方 (既定)
#   --widen    取得者の中で mkdir の成功直後と rm の直前に SEC 秒の sleep を挟む。command を同名の関数で
#              包むので lock.sh は無改変のまま、取得の段と段の間の窓を広げて race を決定的に踏む (既定 0)
#   取得者は daily-research.sh という名前の script で走る (lock.sh は保持者のコマンド行でこの名前を見る)。
#
# 出力: 状況ごとに 1 行
#   state=<s> trials=<T> procs=<N> widen=<w> double=<winner が 2 本以上の trial 数> none=<winner 0 の trial 数>
#   max_winners=<1 trial の winner の最大> leftover=<release 後に lock dir が残った trial 数>
#   stderr_lines=<取得者の stderr の行数 (旧版は奪い合いで消えた dir への pid 書き込みの失敗をここに出す)>
# 終了コード: 0 = 全 trial で winner がちょうど 1 本で lock dir も残らない / 1 = それ以外 / 2 = 使い方の誤り
set -uo pipefail

DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK_SH="$DEV_DIR/../lib/lock.sh"
PROCS=20
TRIALS=50
WIDEN=0
STATE=both

usage() { sed -n '4,13p' "${BASH_SOURCE[0]}" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --lock-sh) LOCK_SH=${2:-}; shift 2 ;;
    --procs) PROCS=${2:-}; shift 2 ;;
    --trials) TRIALS=${2:-}; shift 2 ;;
    --widen) WIDEN=${2:-}; shift 2 ;;
    --state) STATE=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[ -f "$LOCK_SH" ] || { echo "lock.sh が無い: $LOCK_SH" >&2; exit 2; }
LOCK_SH="$(cd "$(dirname "$LOCK_SH")" && pwd)/$(basename "$LOCK_SH")"
case "$STATE" in none) STATES="none" ;; stale) STATES="stale" ;; both) STATES="none stale" ;; *) usage ;; esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 取得者。$1 = lock.sh、$2 = LOCK_DIR、$3 = trial dir、$4 = widen 秒
cat > "$WORK/daily-research.sh" << 'EOF'
#!/bin/bash
LOCK_DIR=$2
T=$3
WIDEN=$4
# shellcheck disable=SC1090
source "$1"
if [ "$WIDEN" != 0 ]; then
  mkdir() { command mkdir "$@" || return; sleep "$WIDEN"; }
  rm() { sleep "$WIDEN"; command rm "$@"; }
fi
: > "$T/ready.$$"
while [ ! -e "$T/go" ]; do :; done
if acquire_lock; then
  echo $$ >> "$T/winners"
  : > "$T/done.$$"
  while [ ! -e "$T/release" ]; do sleep 0.01; done
  release_lock
else
  : > "$T/done.$$"
fi
EOF

count() {  # count <glob の前半> — 一致する file の数
  local n=0 f
  for f in "$1".*; do [ -e "$f" ] && n=$((n + 1)); done
  echo "$n"
}

# wait_for <prefix> <本数> <秒> — 一致する file が本数に届けば 0、時間切れで 1
wait_for() {
  local _
  for _ in $(seq 1 $(($3 * 100))); do
    [ "$(count "$1")" -ge "$2" ] && return 0
    sleep 0.01
  done
  return 1
}

rc=0
for state in $STATES; do
  double=0 none=0 max=0 leftover=0
  for t in $(seq 1 "$TRIALS"); do
    T="$WORK/$state.$t"
    mkdir "$T"
    lock="$T/lock"
    if [ "$state" = stale ]; then
      mkdir "$lock"
      echo 999999999 > "$lock/pid"   # 存在しない PID
    fi
    pids=()
    for _ in $(seq 1 "$PROCS"); do
      /bin/bash "$WORK/daily-research.sh" "$LOCK_SH" "$lock" "$T" "$WIDEN" 3>&- 2>> "$WORK/stderr.$state" &
      pids+=($!)
    done
    hung=0
    wait_for "$T/ready" "$PROCS" 30 || hung=1
    : > "$T/go"
    wait_for "$T/done" "$PROCS" 60 || hung=1
    winners=0
    [ -f "$T/winners" ] && winners=$(wc -l < "$T/winners" | tr -d ' ')
    : > "$T/release"
    if [ "$hung" = 1 ]; then
      kill "${pids[@]}" 2>/dev/null
      echo "trial $state.$t: 取得者が時間内に揃わない・終わらない" >&2
    fi
    wait "${pids[@]}" 2>/dev/null
    [ "$winners" -ge 2 ] && double=$((double + 1))
    [ "$winners" -eq 0 ] && none=$((none + 1))
    [ "$winners" -gt "$max" ] && max=$winners
    [ -d "$lock" ] && leftover=$((leftover + 1))
    rm -rf "$T"
  done
  errs=0
  [ -f "$WORK/stderr.$state" ] && errs=$(wc -l < "$WORK/stderr.$state" | tr -d ' ')
  echo "state=$state trials=$TRIALS procs=$PROCS widen=$WIDEN double=$double none=$none max_winners=$max leftover=$leftover stderr_lines=$errs"
  [ $((double + none + leftover)) -eq 0 ] || rc=1
done
exit "$rc"
