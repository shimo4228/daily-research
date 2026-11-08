#!/bin/bash
# sandbox-run.sh — 本番の scripts/daily-research.sh を 1 line だけ、隔離した PROJECT_DIR と vault の中で
# サブスク (OAuth) の課金経路で回し、成果物を出力 dir に集める (dev 専用。launchd 経路では使わない)。
#
# 使い方:
#   scripts/dev/sandbox-run.sh --line <line> --out <dir> (--ref <git-ref> [--repo <dir>] | --tree <dir>)
#                              [--date YYYY-MM-DD] [--main <dir>] [--prepare-only]
#   --ref   試すコードを git の ref で渡す (git archive で展開。worktree の branch も同じ object DB で引ける)
#   --tree  試すコードを作業ツリーで渡す (tracked + 未追跡の非 ignore file。未 commit の変更を含む。
#           差分は <out>/tree.diff に残す)
#   --main  私的ファイル (config.toml・past_topics.json・state/<line>/) の写し元。既定は git の common dir の親
#   --prepare-only  sandbox を作り検査まで行い、claude を呼ばずに止める (道具自体の試験用)
#
# 隔離の契約:
# - run ごとに <out>/sandbox/project を PROJECT_DIR にする。daily-research.sh は自分の位置から
#   PROJECT_DIR を導くので、lock・logs・state・metrics・past_topics はすべて写しの側に閉じる
# - config.toml は写しで [billing] mode = "subscription"、env_file = <out>/sandbox/no-api-key/env (存在しない)、
#   [general] vault_path = <out>/sandbox/vault (scripts/dev/sandbox_lib.py rewrite-config が他の値の一致を
#   検査する)。実行前に billing-config で再検査する
# - 実行環境は env -i で HOME / USER / LOGNAME / LANG / TMPDIR / PATH と試験 seam だけ (ANTHROPIC_* と
#   CLAUDE* を持ち込まない)。osascript は shim が受けて <out>/notifications.log に残す
# - 実行前に、本番の呼1 / 呼2 / auth probe と同じ cwd・flag で claude を起動し、stream-json の init event で
#   apiKeySource = none (OAuth) を確かめる (init で止めて応答を待たない)。実行後にログの
#   "Billing: subscription" と、呼び出しごとの result JSON の OAuth の印を確かめる。どれかが欠ければ
#   結果は無効 (exit 2)
# - 実行後、本物の vault のレポート dir・MAIN の state / logs / past_topics / metrics / config・接地 repo に
#   run 開始より新しい file が無いことを確かめる (あれば exit 4)
#
# 終了コード: 0 = 有効な run (daily-research.sh も 0) / 1 = 使い方・準備の失敗 / 2 = 課金経路を確認できない /
#             3 = daily-research.sh が非ゼロで終わった (成果物は集めてある) / 4 = 隔離の外に新しい file
set -euo pipefail
# 本体を { … } で囲む: bash は group を読み切ってから実行するので、長い run の途中でこの file が
# 書き換わっても (編集・checkout)、実行中の版の残りが崩れない
{

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SANDBOX_PY="$SELF_DIR/sandbox_lib.py"

die() { echo "sandbox-run: $*" >&2; exit 1; }
usage() { sed -n '4,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 1; }

LINE=""; OUT=""; REF=""; REPO=""; TREE=""; DATE=""; MAIN=""; PREPARE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --line) LINE="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --ref) REF="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --tree) TREE="${2:-}"; shift 2 ;;
    --date) DATE="${2:-}"; shift 2 ;;
    --main) MAIN="${2:-}"; shift 2 ;;
    --prepare-only) PREPARE_ONLY=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$LINE" ] && [ -n "$OUT" ] || usage
printf '%s' "$LINE" | grep -qE '^[A-Za-z0-9_-]+$' || die "line name must match [A-Za-z0-9_-]+: $LINE"
if { [ -n "$REF" ] && [ -n "$TREE" ]; } || { [ -z "$REF" ] && [ -z "$TREE" ]; }; then
  die "pass exactly one of --ref or --tree"
fi
DATE=${DATE:-$(date +%Y-%m-%d)}
printf '%s' "$DATE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || die "--date must be YYYY-MM-DD: $DATE"

# python3 >= 3.11 (tomllib)。launchd と同じく homebrew を先に探す
PY=$(PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" command -v python3) || die "python3 not found"
"$PY" -c 'import tomllib' 2>/dev/null || die "$PY lacks tomllib (need python >= 3.11)"

# 私的ファイルの写し元 (MAIN)。worktree からは git の common dir (= MAIN/.git) の親
if [ -z "$MAIN" ]; then
  _common=$(git -C "$SELF_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || die "cannot derive the main checkout from git; pass --main"
  MAIN=$(dirname "$_common")
fi
MAIN=$(cd "$MAIN" && pwd -P) || die "--main is not a directory: $MAIN"
[ -f "$MAIN/config.toml" ] || die "no config.toml in $MAIN"

# 出力 dir: 空であること。本物の vault・MAIN の state / logs の中と、git の作業ツリーの ignore されない
# 範囲 (公開 repo の追跡対象になりうる場所) には作らない。検査は mkdir より前に行う — まだ無い末尾は、
# 在る最も近い祖先を実体化 (pwd -P) した path に繋いで判定する
_anc=$OUT; _rest=""
while [ ! -d "$_anc" ]; do
  _rest="/$(basename "$_anc")$_rest"
  _anc=$(dirname "$_anc")
done
case "$_rest/" in */./*|*/../*) die "the part of --out that does not exist yet must not contain . or ..: $OUT" ;; esac
OUT="$(cd "$_anc" && pwd -P)$_rest"
# MAIN の config を読むのは道具と同じ checkout の dr_pipeline (試すコードの版に依らない)
TOOL_DR_PY="$SELF_DIR/../lib/dr_pipeline.py"
REAL_VAULT=$("$PY" "$TOOL_DR_PY" vault-path "$MAIN/config.toml" 2>/dev/null) || REAL_VAULT=""
REAL_REPORT_DIR=$("$PY" "$TOOL_DR_PY" report-dir "$MAIN/config.toml" 2>/dev/null) || REAL_REPORT_DIR=""
for _guard in "$REAL_VAULT" "$MAIN/state" "$MAIN/logs"; do
  [ -n "$_guard" ] || continue
  if [ -d "$_guard" ]; then _guard=$(cd "$_guard" && pwd -P); fi
  case "$OUT/" in "$_guard"/*) die "output dir must be outside $_guard" ;; esac
done
_top=$(git -C "$_anc" rev-parse --show-toplevel 2>/dev/null) || _top=""
if [ -n "$_top" ] && ! git -C "$_top" check-ignore -q "$OUT"; then
  die "output dir is inside the git work tree $_top and not ignored — use an ignored path such as .notes/"
fi
mkdir -p "$OUT"
[ -z "$(ls -A "$OUT")" ] || die "output dir is not empty: $OUT"

SANDBOX="$OUT/sandbox"
PROJ="$SANDBOX/project"
VAULT="$SANDBOX/vault"
SHIM_DIR="$SANDBOX/bin"
META_TSV="$SANDBOX/meta.tsv"
mkdir -p "$PROJ" "$VAULT" "$SHIM_DIR"
: > "$META_TSV"
meta() { printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t\n' '  ')" >> "$META_TSV"; }
meta line "$LINE"
meta date "$DATE"
meta out "$OUT"
meta main "$MAIN"

# === 試すコードを PROJECT_DIR に展開する ===
if [ -n "$REF" ]; then
  REPO=${REPO:-$MAIN}
  SHA=$(git -C "$REPO" rev-parse --verify "${REF}^{commit}" 2>/dev/null) || die "unknown git ref: $REF"
  git -C "$REPO" archive --format=tar "$SHA" | tar -x -C "$PROJ"
  meta source_kind ref
  meta source_ref "$REF"
  meta source_sha "$SHA"
else
  TOP=$(git -C "$TREE" rev-parse --show-toplevel 2>/dev/null) || die "--tree is not a git work tree: $TREE"
  SHA=$(git -C "$TOP" rev-parse HEAD)
  LIST="$SANDBOX/tree-files"
  : > "$LIST"
  # tracked + 未追跡の非 ignore。作業ツリーで消した file・入れ子の repo (末尾 /)・worktree は除く
  while IFS= read -r -d '' _f; do
    case "$_f" in */|.claude/worktrees/*) continue ;; esac
    if [ -f "$TOP/$_f" ]; then printf '%s\0' "$_f" >> "$LIST"; fi
  done < <(git -C "$TOP" ls-files -z -co --exclude-standard)
  tar -c -f - -C "$TOP" --null -T "$LIST" | tar -x -C "$PROJ"
  git -C "$TOP" diff HEAD --binary > "$OUT/tree.diff"
  meta source_kind tree
  meta source_ref "$TOP"
  meta source_sha "$SHA"
  meta source_dirty:int "$(git -C "$TOP" status --porcelain | wc -l | tr -d ' ')"
  meta source_untracked:json "$(git -C "$TOP" ls-files -z -o --exclude-standard \
    | "$PY" -c 'import json,sys; print(json.dumps([p for p in sys.stdin.read().split(chr(0)) if p]))')"
fi
[ -f "$PROJ/scripts/daily-research.sh" ] || die "the code under test has no scripts/daily-research.sh"
DR_PY="$PROJ/scripts/lib/dr_pipeline.py"

# === 私的ファイルを MAIN から写す ===
# env_file は存在しない path に向ける (本物の key file に届く経路を残さない)。置き場は専用の subdir:
# daily-research.sh は env_file の dir 全体に Read deny を置くので、$SANDBOX 直下だと project と vault の
# Read まで塞がる。dir は作らない
NO_KEY_ENV="$SANDBOX/no-api-key/env"
"$PY" "$SANDBOX_PY" rewrite-config "$MAIN/config.toml" "$PROJ/config.toml" "$VAULT" "$NO_KEY_ENV" \
  || die "config rewrite failed"
if [ -f "$MAIN/past_topics.json" ]; then
  cp "$MAIN/past_topics.json" "$PROJ/past_topics.json"
  chmod 600 "$PROJ/past_topics.json"
fi
# state/<line>: brief.md / pending.md / watched-sources.md と過去の runs/。当日の runs/<date>.* は写さない
# (呼1 が「今日は済んだ」と読む・gate が古い receipt を拾う、を避ける)。mtime は保つ。symlink は実体を
# 写す (-L): link のまま写すと、呼1 の pending.md への書き込みが link 先の本物に届く
mkdir -p "$PROJ/state"
if [ -d "$MAIN/state/$LINE" ]; then
  cp -RLp "$MAIN/state/$LINE" "$PROJ/state/$LINE"
  rm -f "$PROJ/state/$LINE/runs/$DATE".*
  [ -z "$(find "$PROJ/state/$LINE" -type l | head -n 1)" ] || die "symlinks survived the copy of state/$LINE"
fi
for _f in pending.md watched-sources.md; do
  if [ -f "$PROJ/state/$LINE/$_f" ]; then cp -p "$PROJ/state/$LINE/$_f" "$OUT/${_f%.md}.before.md"; fi
done

# 写した config の検査: line が在ること・課金経路が subscription であること (試すコードの dr_pipeline で)
TRACKS_TSV=$("$PY" "$DR_PY" tracks "$PROJ/config.toml") || die "the copied config.toml fails the schema check"
LINE_ROW=$(printf '%s\n' "$TRACKS_TSV" | awk -F'\t' -v l="$LINE" '$1 == l { print; exit }')
[ -n "$LINE_ROW" ] || die "line $LINE is not in config.toml"
BILLING_TSV=$("$PY" "$DR_PY" billing-config "$PROJ/config.toml") || die "billing-config rejected the copied config"
[ "${BILLING_TSV%%$'\t'*}" = "subscription" ] || die "copied config is not subscription mode (${BILLING_TSV%%$'\t'*}) — refusing to run"
_env_file=${BILLING_TSV#*$'\t'}; _env_file=${_env_file%%$'\t'*}
[ "$_env_file" = "$NO_KEY_ENV" ] || die "copied config's env_file is $_env_file, not the sandbox placeholder"
[ ! -e "$NO_KEY_ENV" ] || die "the env_file placeholder exists: $NO_KEY_ENV"
REPORT_DIR=$("$PY" "$DR_PY" report-dir "$PROJ/config.toml")
case "$REPORT_DIR" in "$VAULT"/*) ;; *) die "report dir is outside the sandbox vault: $REPORT_DIR" ;; esac
mkdir -p "$REPORT_DIR"
LINE_MODE=$("$PY" "$DR_PY" config-get "$PROJ/config.toml" "tracks.$LINE.mode" repo)
TARGET_REPO=""
if [ "$LINE_MODE" = "repo" ]; then
  TARGET_REPO=${LINE_ROW##*$'\t'}
  [ -d "$TARGET_REPO" ] || die "target repo of $LINE does not exist: $TARGET_REPO"
fi
meta mode "$LINE_MODE"
meta target_repo "$TARGET_REPO"
"$PY" "$SANDBOX_PY" line-history "$PROJ/past_topics.json" "$PROJ/config.toml" "$LINE" "$OUT/past_topics.line.json"

# === 実行環境: launchd に近い掃除した環境 + osascript の shim ===
cat > "$SHIM_DIR/osascript" << EOF
#!/bin/bash
printf '%s\t%s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$*" >> "$OUT/notifications.log"
exit 0
EOF
chmod 755 "$SHIM_DIR/osascript"
CLEAN_TMPDIR=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || CLEAN_TMPDIR=""
CLEAN_TMPDIR=${CLEAN_TMPDIR:-${TMPDIR:-/tmp}}
CLEAN_PATH="$SHIM_DIR:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
CLEAN_ENV=(env -i HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-${USER:-$(id -un)}}"
  LANG="${LANG:-en_US.UTF-8}" TMPDIR="$CLEAN_TMPDIR" PATH="$CLEAN_PATH")

# env.sh が PATH の先頭に足す dir より後ろでも、shim が /usr/bin の osascript に勝つことを確かめる
# (試すコードの env.sh を、run と同じ掃除した環境で source して解決先を見る)
RESOLVED=$("${CLEAN_ENV[@]}" /bin/bash -c '. "$1" && command -v osascript' _ "$PROJ/scripts/lib/env.sh")
[ "$RESOLVED" = "$SHIM_DIR/osascript" ] || die "osascript resolves to $RESOLVED, not the shim"
CLAUDE_BIN=$("${CLEAN_ENV[@]}" /bin/bash -c '. "$1" && command -v claude' _ "$PROJ/scripts/lib/env.sh") \
  || die "claude is not on the clean PATH"
meta claude_bin "$CLAUDE_BIN"
meta claude_version "$("${CLEAN_ENV[@]}" "$CLAUDE_BIN" --version 2>/dev/null || echo unknown)"

if [ "$PREPARE_ONLY" = "1" ]; then
  meta prepared_only:int 1
  echo "sandbox-run: prepared $PROJ (line $LINE, date $DATE, mode $LINE_MODE) — not running (--prepare-only)"
  exit 0
fi

# 課金経路の事前確認。key は env だけでなく cwd の .claude/settings*.json (env / apiKeyHelper) からも
# 入るので、本番が claude を起動する 3 つの条件をそれぞれ probe する:
#   call1    = 呼1 の cwd (repo line は接地 repo、ecosystem line は state/<line>) + --safe-mode
#   call2    = 呼2 の cwd (PROJECT_DIR) + --safe-mode
#   dr_probe = daily-research.sh 自身の auth probe (cwd = PROJECT_DIR、--safe-mode なし)
# auth-probe は stream-json の init event を読んだ時点で claude を止め、応答を待たない (timeout 付き)。
# 最初に none 以外を見た probe で止め、残りは起動しない
if [ "$LINE_MODE" = "ecosystem" ]; then CALL1_CWD="$PROJ/state/$LINE"; else CALL1_CWD="$TARGET_REPO"; fi
[ -d "$CALL1_CWD" ] || die "call 1 cwd does not exist: $CALL1_CWD"
PROBE_TIMEOUT_S=60
AUTH_SOURCE=none
probe_auth() {  # $1 = label, $2 = cwd, $3… = 本番の呼び出しと揃える flag
  local label=$1 cwd=$2 res value reason
  shift 2
  [ "$AUTH_SOURCE" = "none" ] || return 0
  res=$("${CLEAN_ENV[@]}" "$PY" "$SANDBOX_PY" auth-probe --cwd "$cwd" --timeout "$PROBE_TIMEOUT_S" -- \
    "$CLAUDE_BIN" -p ok --max-turns 1 --model haiku ${1+"$@"} \
    --output-format stream-json --verbose --no-session-persistence) || res=""
  value=${res%%$'\t'*}
  reason=${res#*$'\t'}
  meta "auth_probe_$label" "$value ($reason) cwd=$cwd"
  if [ "$value" != "none" ]; then
    AUTH_SOURCE=${value:-unknown}
    echo "sandbox-run: probe $label (cwd $cwd): apiKeySource is '$AUTH_SOURCE' ($reason), not none (OAuth) — refusing to run" >&2
  fi
}
probe_auth call1 "$CALL1_CWD" --safe-mode
probe_auth call2 "$PROJ" --safe-mode
probe_auth dr_probe "$PROJ"
meta api_key_source "$AUTH_SOURCE"
[ "$AUTH_SOURCE" = "none" ] || exit 2

# === 実行 ===
MARKER="$SANDBOX/.run-start"
touch "$MARKER"
LOG="$PROJ/logs/$DATE.log"
START=$(date +%s)
meta started_at "$(date '+%Y-%m-%dT%H:%M:%S%z')"
( cd "$PROJ" && "${CLEAN_ENV[@]}" DR_FORCE_TRACK="$LINE" DR_DATE="$DATE" \
    /bin/bash "$PROJ/scripts/daily-research.sh" ) > "$OUT/stdout.log" 2>&1 &
RUN_PID=$!
# 呼2 は原稿をその場で改稿するので、"=== Clarity pass: <note> ===" の行が出た時点で呼1 の原稿を写す
DRAFT_TAKEN=0
while kill -0 "$RUN_PID" 2>/dev/null; do
  if [ "$DRAFT_TAKEN" = "0" ] && [ -f "$LOG" ]; then
    _note=$(sed -n 's/^\[[^]]*\] === Clarity pass: \(.*\) ===$/\1/p' "$LOG" | tail -n 1)
    if [ -n "$_note" ] && [ -f "$REPORT_DIR/$_note" ]; then
      cp -p "$REPORT_DIR/$_note" "$OUT/draft.md"
      DRAFT_TAKEN=1
    fi
  fi
  sleep 1
done
DR_EXIT=0
wait "$RUN_PID" || DR_EXIT=$?
meta dr_exit:int "$DR_EXIT"
meta duration_s:int "$(( $(date +%s) - START ))"

# === 集約と検査 ===
COLLECT_RC=0
"$PY" "$SANDBOX_PY" collect --proj "$PROJ" --out "$OUT" --line "$LINE" --date "$DATE" \
  --report-dir "$REPORT_DIR" --real-report-dir "$REAL_REPORT_DIR" --marker "$MARKER" \
  --main "$MAIN" --target "$TARGET_REPO" --meta-tsv "$META_TSV" || COLLECT_RC=$?
if [ "$COLLECT_RC" != "0" ]; then
  exit "$COLLECT_RC"
fi
[ "$DR_EXIT" = "0" ] || exit 3
exit 0
}
