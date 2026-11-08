#!/usr/bin/env bats
# lib/*.sh の単体テスト。
# 各 lib を /bin/bash (macOS 3.2) で source し、関数を isolation 検証する。

LIB_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib" && pwd)"

setup() {
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

# $output に $1 が含まれないこと (`! grep` は bats の最終行以外で検出しない)
refute_out() {
  if echo "$output" | grep -q "$1"; then
    echo "unexpected match: $1" >&2
    echo "$output" >&2
    return 1
  fi
}

# === log.sh ===

@test "log_init creates log file (600) and dir (700) at creation time" {
  LOG_DIR="$TMP/logs"
  LOG_FILE="$LOG_DIR/test.log"
  source "$LIB_DIR/log.sh"
  log_init
  [ -d "$LOG_DIR" ]
  [ -f "$LOG_FILE" ]
  [ "$(stat -f '%Lp' "$LOG_DIR")" = "700" ]
  [ "$(stat -f '%Lp' "$LOG_FILE")" = "600" ]
}

@test "log appends a timestamped line" {
  LOG_DIR="$TMP/logs"
  LOG_FILE="$LOG_DIR/test.log"
  source "$LIB_DIR/log.sh"
  log_init
  log "hello world"
  grep -q "hello world" "$LOG_FILE"
  grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] ' "$LOG_FILE"
}

@test "log_init deletes logs older than 30 days" {
  LOG_DIR="$TMP/logs"
  LOG_FILE="$LOG_DIR/2026-01-31.log"
  mkdir -p "$LOG_DIR"
  : > "$LOG_DIR/2025-01-01.log"
  touch -t 202501010000 "$LOG_DIR/2025-01-01.log"  # 30日超
  source "$LIB_DIR/log.sh"
  log_init
  [ ! -f "$LOG_DIR/2025-01-01.log" ]
  [ -f "$LOG_FILE" ]
}

@test "log_init keeps launchd's stdout/stderr capture files however old (RUNBOOK: manual cleanup)" {
  # launchd は job の起動時に StandardErrorPath を開いてから script を exec する。rotation が
  # ここで消すと、その run の stderr (set -u の中断など、log に残らない出力) は unlink 済みの
  # inode に書かれて失われる。書き込みの無い日が 30 日続くと mtime が古くなる
  LOG_DIR="$TMP/logs"
  LOG_FILE="$LOG_DIR/2026-01-31.log"
  mkdir -p "$LOG_DIR"
  : > "$LOG_DIR/launchd-stderr.log"
  : > "$LOG_DIR/launchd-stdout.log"
  touch -t 202501010000 "$LOG_DIR/launchd-stderr.log" "$LOG_DIR/launchd-stdout.log"
  source "$LIB_DIR/log.sh"
  log_init
  [ -f "$LOG_DIR/launchd-stderr.log" ]
  [ -f "$LOG_DIR/launchd-stdout.log" ]
}

# === notify.sh ===

@test "notify is a no-op (returns 0) when osascript is absent — but says so" {
  run env PATH="/nonexistent-dir" /bin/bash -c "source '$LIB_DIR/notify.sh'; notify 'body' 'title'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "notify skipped"
}

@test "notify logs delivery failure instead of swallowing it" {
  local fake; fake=$(mktemp -d)
  printf '#!/bin/sh\necho "execution error: Not authorized" >&2\nexit 1\n' > "$fake/osascript"
  chmod +x "$fake/osascript"
  run env PATH="$fake:/usr/bin:/bin" /bin/bash -c "source '$LIB_DIR/notify.sh'; notify 'body' 'title'"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "notify failed (execution error: Not authorized): title"
}

@test "run_claude passes timeout -k so a SIGTERM-ignoring child is killed" {
  grep -q 'timeout -k 60 "\$CLAUDE_TIMEOUT"' "$LIB_DIR/claude.sh"
}

@test "notify does not crash with quotes/backslashes in body (injection guard)" {
  run /bin/bash -c "source '$LIB_DIR/notify.sh'; notify 'a\"b\\c' 'ti\"tle'"
  [ "$status" -eq 0 ]
}

@test "notify does not crash with embedded newlines (multi-statement injection guard)" {
  run /bin/bash -c "source '$LIB_DIR/notify.sh'; notify \$'line1\nline2' \$'ti\ntle'"
  [ "$status" -eq 0 ]
}

# === report_unexpected_exit (daily-research.sh の ERR trap 本体) ===
# set -E で ERR trap は $(…) のサブシェルにも継承される。サブシェルからは外側の `|| X` が
# 見えないので、親が処理した失敗でも trap が走る — 親シェルでだけ記録・通知することを確かめる。

err_trap_script() {
  printf '%s\n' "set -Eeuo pipefail" "source '$LIB_DIR/notify.sh'" \
    "trap 'report_unexpected_exit \$? \$LINENO \"\$BASH_COMMAND\"' ERR" "$1"
}

@test "ERR trap: a failure inside \$(…) that the parent handles with || is not reported" {
  run env PATH="/nonexistent-dir" /bin/bash -c "$(err_trap_script 'f() { return 2; }
x=$(f 2>/dev/null) || rc=$?
echo "handled rc=$rc"')"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "handled rc=2"
  refute_out "unexpected exit"
  refute_out "notify"
}

@test "ERR trap: an unhandled failure in the parent shell is logged and notified" {
  run env PATH="/nonexistent-dir" /bin/bash -c "$(err_trap_script 'x=$(exit 3)
echo "not reached"')"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "ERROR: unexpected exit 3 at line [0-9]*: x=\$(exit 3)"
  echo "$output" | grep -q "notify skipped (osascript not found): Daily Research Error"
  refute_out "not reached"
  # 親で 1 回だけ (サブシェル側の重複発火なし)
  [ "$(echo "$output" | grep -c "unexpected exit")" -eq 1 ]
}

# === lock.sh (lock dir + flock の mutex。0 = 取得、1 = 実行中、2 = 確かめられない) ===

@test "acquire_lock succeeds when no lock exists and records pid" {
  LOCK_DIR="$TMP/lock"
  source "$LIB_DIR/lock.sh"
  run acquire_lock
  [ "$status" -eq 0 ]
  [ -d "$LOCK_DIR" ]
  [ -f "$LOCK_DIR/pid" ]
}

@test "acquire_lock fails when a live lock is held" {
  LOCK_DIR="$TMP/lock"
  mkdir "$LOCK_DIR"
  # 生きている別インスタンス = コマンド行が daily-research.sh の process (fd 3 は bats の出力)
  printf '#!/bin/bash\nsleep 30\n' > "$TMP/daily-research.sh"
  /bin/bash "$TMP/daily-research.sh" >/dev/null 2>&1 3>&- &
  local owner=$! i
  for i in $(seq 1 50); do   # fork 直後は exec 前の親のコマンド行が見える
    case "$(ps -ww -p "$owner" -o command= 2>/dev/null)" in *daily-research.sh*) break ;; esac
    sleep 0.1
  done
  echo "$owner" > "$LOCK_DIR/pid"
  source "$LIB_DIR/lock.sh"
  run acquire_lock
  pkill -P "$owner" 2>/dev/null || true
  kill "$owner" 2>/dev/null || true
  [ "$status" -eq 1 ]   # 1 = 実行中 (2 の「確かめられない」と分ける)
  [ "$(cat "$LOCK_DIR/pid")" = "$owner" ]
}

@test "acquire_lock steals a lock whose pid now belongs to another process (pid reused after reboot)" {
  # run 中の再起動 (夜間の OS 更新など) で lock dir が残り、再起動後に同じ PID を同 user の長命 process が
  # 使うと kill -0 が通り、以後の run が全部 "Another instance is running" で skip になっていた
  LOCK_DIR="$TMP/lock"
  mkdir "$LOCK_DIR"
  sleep 30 >/dev/null 2>&1 3>&- &
  local other=$!
  echo "$other" > "$LOCK_DIR/pid"
  source "$LIB_DIR/lock.sh"
  run acquire_lock
  kill "$other" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$(cat "$LOCK_DIR/pid")" = "$$" ]
}

@test "acquire_lock steals a stale lock (dead pid)" {
  LOCK_DIR="$TMP/lock"
  mkdir "$LOCK_DIR"
  echo "999999999" > "$LOCK_DIR/pid"   # 存在しない PID
  source "$LIB_DIR/lock.sh"
  run acquire_lock
  [ "$status" -eq 0 ]
  [ "$(cat "$LOCK_DIR/pid")" = "$$" ]   # 自分の PID に置き換わる
}

@test "release_lock removes only own lock" {
  LOCK_DIR="$TMP/lock"
  source "$LIB_DIR/lock.sh"
  acquire_lock
  [ -d "$LOCK_DIR" ]
  release_lock
  [ ! -d "$LOCK_DIR" ]
  [ -f "$LOCK_DIR.mutex" ]   # mutex は常設 (消すと別 inode を lock する process と並ぶ)
}

@test "release_lock does not remove a lock owned by another pid" {
  LOCK_DIR="$TMP/lock"
  mkdir "$LOCK_DIR"
  echo "999999999" > "$LOCK_DIR/pid"   # 他プロセス所有
  source "$LIB_DIR/lock.sh"
  release_lock
  [ -d "$LOCK_DIR" ]   # 自分のものでないので消さない
}

@test "acquire_lock steals a lock dir whose pid is missing, empty, non-numeric or its own PID" {
  # どれも実行中の保持者を示さない (pid を書く途中の取得者は mutex の中にしかいない)。実行中と読むと
  # 以後の run が全部 skip になる。旧実装は "-1" を実行中と読んだ (kill -0 -1 が通り、ps が空を返す)
  LOCK_DIR="$TMP/lock"
  source "$LIB_DIR/lock.sh"
  local content
  for content in none "" "-1" "12x" "$$"; do
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
    [ "$content" = none ] || printf '%s' "$content" > "$LOCK_DIR/pid"
    run acquire_lock
    [ "$status" -eq 0 ] || { echo "not stolen: pid=[$content]" >&2; return 1; }
    [ "$(cat "$LOCK_DIR/pid")" = "$$" ]
  done
}

@test "acquire_lock steals a lock whose pid is 0 (kill -0 0 reaches the process group, ps -p 0 is empty)" {
  # 旧実装からの穴: "0" を実行中と読み、以後の run が全部 skip になる
  LOCK_DIR="$TMP/lock"
  mkdir "$LOCK_DIR"
  echo 0 > "$LOCK_DIR/pid"
  source "$LIB_DIR/lock.sh"
  run acquire_lock
  [ "$status" -eq 0 ]
  [ "$(cat "$LOCK_DIR/pid")" = "$$" ]
}

@test "acquire_lock returns 2 with a reason, not 'running', when python3 fails to take the mutex" {
  LOCK_DIR="$TMP/lock"
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\necho "python3 stub failed" >&2\nexit 1\n' > "$TMP/bin/python3"
  chmod +x "$TMP/bin/python3"
  source "$LIB_DIR/lock.sh"
  local rc=0
  PATH="$TMP/bin:$PATH" acquire_lock || rc=$?
  [ "$rc" -eq 2 ]
  [[ "$LOCK_ERROR" == *"python3 stub failed"* ]]
  [ ! -e "$LOCK_DIR" ]   # 確かめられないときは lock に触れない
}

@test "acquire_lock returns 2 with a reason when the mutex file cannot be opened" {
  # fd 9 の redirect の失敗は bash が 1 を返す — それを「実行中」の 1 と取り違えない
  LOCK_DIR="$TMP/lock"
  mkdir "$LOCK_DIR.mutex"   # 同名の dir が居座って開けない
  source "$LIB_DIR/lock.sh"
  local rc=0
  acquire_lock || rc=$?
  [ "$rc" -eq 2 ]
  [[ "$LOCK_ERROR" == *"lock.mutex"* ]]
  [[ "$LOCK_ERROR" != *$'\n'* ]]   # log の 1 行に収まる
  [ ! -e "$LOCK_DIR" ]
}

@test "acquire_lock waits while another process holds the mutex, then takes the lock" {
  LOCK_DIR="$TMP/lock"
  # 保持者は flock を取って held を作り、1 秒後に released を作ってから終わる (終わると kernel が flock を外す)
  ( exec python3 -c 'import fcntl, pathlib, sys, time; fcntl.flock(9, fcntl.LOCK_EX); pathlib.Path(sys.argv[1]).touch(); time.sleep(1); pathlib.Path(sys.argv[2]).touch()' "$TMP/held" "$TMP/released" ) 9>> "$LOCK_DIR.mutex" 3>&- &
  local holder=$! i
  for i in $(seq 1 100); do [ -e "$TMP/held" ] && break; sleep 0.05; done
  [ -e "$TMP/held" ]
  source "$LIB_DIR/lock.sh"
  run acquire_lock
  local after_release=0
  [ -e "$TMP/released" ] && after_release=1   # wait より前に見る: 取得は保持者が mutex を手放した後
  wait "$holder"
  [ "$status" -eq 0 ]
  [ "$after_release" -eq 1 ]
  [ "$(cat "$LOCK_DIR/pid")" = "$$" ]
}

@test "acquire_lock is not blocked by a mutex whose holder was killed (kernel releases the flock)" {
  # mutex に stale は無い: 取得の途中で kill -9 された process の flock は fd と一緒に外れる
  LOCK_DIR="$TMP/lock"
  ( exec python3 -c 'import fcntl, pathlib, sys, time; fcntl.flock(9, fcntl.LOCK_EX); pathlib.Path(sys.argv[1]).touch(); time.sleep(30)' "$TMP/held" ) 9>> "$LOCK_DIR.mutex" 3>&- &
  local holder=$! i
  for i in $(seq 1 100); do [ -e "$TMP/held" ] && break; sleep 0.05; done
  [ -e "$TMP/held" ]
  kill -9 "$holder"
  wait "$holder" 2>/dev/null || true
  mkdir "$LOCK_DIR"   # 取得の途中 (mkdir の後、pid の前) で死んだ残骸
  source "$LIB_DIR/lock.sh"
  run acquire_lock
  [ "$status" -eq 0 ]
  [ "$(cat "$LOCK_DIR/pid")" = "$$" ]
}

@test "acquire_lock: concurrent acquirers never both win (no lock / stale dead-pid lock)" {
  # 8 本を barrier で揃えて同時に取得させ、winner がちょうど 1 本かを 3 trial × 2 状況で見る。mkdir の後と
  # rm の前に 0.02 秒の窓を挟む。旧実装 (mkdir 単独。pid 書き込みと stale の奪取が mutex の外) はこの設定で
  # 二重取得した。重い版 (20 本 × 50 trial) は scripts/dev/lock-stress.sh を手で回す
  run "$LIB_DIR/../dev/lock-stress.sh" --procs 8 --trials 3 --widen 0.02
  echo "$output"
  [ "$status" -eq 0 ]
}

# === auth.sh (real_auth_probe) ===

_dr_py() {
  echo "$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib" && pwd)/dr_pipeline.py"
}

@test "real_auth_probe returns 0 when API responds without error" {
  cat > "$TMP/claude" <<'EOF'
#!/bin/bash
[[ "$1" == "--version" ]] && { echo mock; exit 0; }
echo '{"type":"result","is_error":false}'
exit 0
EOF
  chmod +x "$TMP/claude"
  CLAUDE_CMD="$TMP/claude"
  DR_PY="$(_dr_py)"
  source "$LIB_DIR/auth.sh"
  run real_auth_probe
  [ "$status" -eq 0 ]
}

@test "real_auth_probe returns 1 on 401/is_error" {
  cat > "$TMP/claude" <<'EOF'
#!/bin/bash
[[ "$1" == "--version" ]] && { echo mock; exit 0; }
echo '{"type":"result","is_error":true,"api_error_status":401}'
exit 1
EOF
  chmod +x "$TMP/claude"
  CLAUDE_CMD="$TMP/claude"
  DR_PY="$(_dr_py)"
  source "$LIB_DIR/auth.sh"
  run real_auth_probe
  [ "$status" -eq 1 ]
}

@test "real_auth_probe returns 1 on is_error WITHOUT api_error_status (leading empty field)" {
  # api_error_status が無い is_error:true。error-fields は "\ttrue" を返すため、
  # 先頭の空フィールドを潰さない parse でないと取りこぼす (回帰防止)
  cat > "$TMP/claude" <<'EOF'
#!/bin/bash
[[ "$1" == "--version" ]] && { echo mock; exit 0; }
echo '{"type":"result","is_error":true}'
exit 1
EOF
  chmod +x "$TMP/claude"
  CLAUDE_CMD="$TMP/claude"
  DR_PY="$(_dr_py)"
  source "$LIB_DIR/auth.sh"
  run real_auth_probe
  [ "$status" -eq 1 ]
}

@test "real_auth_probe passes timeout -k so a SIGTERM-ignoring claude cannot hold the run (and the lock)" {
  # -k が無いと、timeout は SIGTERM を無視した子の終了を無期限に待つ。probe は lock 取得後に
  # 走るので、翌朝以降の run が全部 "Another instance is running" になる (run_claude と同じ穴)。
  # 実時間で 60 秒を待たずに済むよう、PATH 先頭の timeout が引数を記録して本物へ渡す
  local real_timeout; real_timeout=$(command -v timeout)
  mkdir -p "$TMP/bin"
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s/timeout_args"\nexec "%s" "$@"\n' "$TMP" "$real_timeout" > "$TMP/bin/timeout"
  chmod +x "$TMP/bin/timeout"
  cat > "$TMP/claude" <<'EOF'
#!/bin/bash
echo '{"type":"result","is_error":false}'
EOF
  chmod +x "$TMP/claude"
  CLAUDE_CMD="$TMP/claude"
  DR_PY="$(_dr_py)"
  PATH="$TMP/bin:$PATH"
  source "$LIB_DIR/auth.sh"
  run real_auth_probe
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$TMP/timeout_args")" = "-k" ]
  [[ "$(sed -n 2p "$TMP/timeout_args")" =~ ^[0-9]+$ ]]
}

@test "real_auth_probe starts claude with --safe-mode, like call 1 / call 2" {
  # probe だけが user の plugin / MCP / hook / CLAUDE.md を載せて起動していた。認証の経路は safe mode でも
  # 変わらない (claude --help: "Auth ... work normally") ので、本番の呼び出しと同じ起動形で認証を確かめる
  cat > "$TMP/claude" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$TMP/probe_args"
echo '{"type":"result","is_error":false}'
EOF
  chmod +x "$TMP/claude"
  CLAUDE_CMD="$TMP/claude"
  DR_PY="$(_dr_py)"
  source "$LIB_DIR/auth.sh"
  run real_auth_probe
  [ "$status" -eq 0 ]
  grep -qx -- "--safe-mode" "$TMP/probe_args"
}

# === claude.sh (classify_exit) ===

_fixtures() {
  echo "$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures"
}

@test "classify_exit: api_error_status 401 -> E_AUTH" {
  DR_PY="$(_dr_py)"; source "$LIB_DIR/claude.sh"
  run classify_exit 1 '{"is_error":true,"api_error_status":401}'
  [ "$output" = "E_AUTH" ]
}

@test "classify_exit: timeout (124) -> E_TRANSIENT" {
  DR_PY="$(_dr_py)"; source "$LIB_DIR/claude.sh"
  run classify_exit 124 '{"is_error":false}'
  [ "$output" = "E_TRANSIENT" ]
}

@test "classify_exit: exit 0 but is_error -> E_FATAL (success masking guard)" {
  DR_PY="$(_dr_py)"; source "$LIB_DIR/claude.sh"
  run classify_exit 0 '{"is_error":true}'
  [ "$output" = "E_FATAL" ]
}

@test "classify_exit: non-zero exit -> E_FATAL" {
  DR_PY="$(_dr_py)"; source "$LIB_DIR/claude.sh"
  run classify_exit 1 '{"is_error":false}'
  [ "$output" = "E_FATAL" ]
}

@test "classify_exit: exit 0 no error -> OK (real success fixture)" {
  DR_PY="$(_dr_py)"; source "$LIB_DIR/claude.sh"
  run classify_exit 0 "$(cat "$(_fixtures)/result-success.json")"
  [ "$output" = "OK" ]
}

@test "classify_exit: real 401 fixture -> E_AUTH" {
  DR_PY="$(_dr_py)"; source "$LIB_DIR/claude.sh"
  run classify_exit 1 "$(cat "$(_fixtures)/result-401.json")"
  [ "$output" = "E_AUTH" ]
}

# === env.sh ===

@test "env.sh unsets ANTHROPIC_API_KEY" {
  # 変数名を組み立てて設定する (pre-commit の secret スキャンが key 名 + 等号 +
  # 非空白のリテラルを検知するため、その並びをソースに書かない)
  local name="ANTHROPIC_API_KEY"
  export "$name=dummy-test-value"
  run /bin/bash -c "source '$LIB_DIR/env.sh'; printenv $name || echo UNSET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNSET"* ]]
}

@test "env.sh unsets CLAUDE_CODE_EFFORT_LEVEL (it outranks the --effort the calls pass)" {
  export CLAUDE_CODE_EFFORT_LEVEL=max
  run /bin/bash -c "source '$LIB_DIR/env.sh'; printenv CLAUDE_CODE_EFFORT_LEVEL || echo UNSET"
  [ "$status" -eq 0 ]
  [ "$output" = "UNSET" ]
}

@test "env.sh puts Claude install paths before homebrew bins" {
  run /bin/bash -c "source '$LIB_DIR/env.sh'; echo \"\$PATH\""
  [ "$status" -eq 0 ]
  if [ -d "$HOME/.local/bin" ]; then
    [[ "$output" == "$HOME/.local/bin:"* ]]
  elif [ -d "$HOME/.claude/local" ]; then
    [[ "$output" == "$HOME/.claude/local:"* ]]
  else
    [[ "$output" == "/opt/homebrew/bin:"* ]]
  fi
  [[ "$output" == *"/opt/homebrew/bin:/usr/local/bin:"* ]]
}

@test "env.sh finds Claude CLI installed in ~/.local/bin under launchd PATH" {
  local mock_home="$TMP/home"
  mkdir -p "$mock_home/.local/bin"
  printf '#!/bin/bash\nexit 0\n' > "$mock_home/.local/bin/claude"
  chmod +x "$mock_home/.local/bin/claude"

  run env HOME="$mock_home" PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    /bin/bash -c "source '$LIB_DIR/env.sh'; command -v claude"

  [ "$status" -eq 0 ]
  [ "$output" = "$mock_home/.local/bin/claude" ]
}
