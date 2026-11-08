#!/usr/bin/env bash
# lock.sh — daily-research の同時実行ロック。source 専用。
# LOCK_DIR を呼び出し側で定義済みであること。lock は dir の LOCK_DIR と、その中の pid (保持者の PID。
# mtime は daily-research.sh の find_run_file が run の開始時刻として使う)。
#
# 保証: acquire_lock が 0 を返した process は同時に高々 1 つ (保持者が daily-research.sh の名前で走っている
# 限り — コマンド行がこの名前でない保持者は PID 再利用の stale と読んで奪う)。lock の判定と変更 (pid の読み・
# stale の奪取・mkdir・pid の書き込み・release の削除) は、すべて "$LOCK_DIR.mutex" に取る flock(2) の中で行う。
# flock は fd を持つ process が全部終わると kernel が外すので、mutex に stale は無い (取得中に死んでも残らない)。
# mutex のファイルは消さない — 消すと、古い inode を lock した process と新しい inode を lock した process が並ぶ。

# _lock_mutex: 呼び出し側の subshell が開いた fd 9 ("$LOCK_DIR.mutex") に排他 flock を取る。10 秒で取れなければ 1。
# python は flock を取って終わるだけで、lock は fd 9 を開いた subshell が終わるまで続く (flock は open file に付く)。
# -I: cwd・PYTHON* 環境変数・user site を読まない (cwd の同名 module に差し替えられない)。
_lock_mutex() {
  python3 -I -c '
import fcntl, signal, sys
signal.signal(signal.SIGALRM, lambda *_: sys.exit("lock: " + sys.argv[1] + " の flock を 10 秒待っても取れない"))
signal.alarm(10)
fcntl.flock(9, fcntl.LOCK_EX)
' "$LOCK_DIR.mutex"
}

# _lock_held: LOCK_DIR を実行中の daily-research が持っていれば 0、stale なら 1。mutex の中で呼ぶ。
# pid が無い・空・数字でない lock dir は stale — pid を書き込み中の取得者は mutex の中にしかおらず、mutex を
# 持つのは呼び出し側なので、それは取得中に死んだ process の残骸。0 で始まる pid も stale (書くのは $$ だけ。
# kill -0 0 は自分の process group に通り、ps -p 0 は空を返すので、実行中と読み続ける)。pid が自分の PID
# なのも stale (取得前の自分は保持者でない。再起動前の run の lock に残った PID を、再起動後の自分が引いた)。
# PID が生きていても、その process のコマンド行が daily-research.sh でないと読めたときは stale — run 中の
# 再起動で lock dir が残り、再起動後に同じ PID を別の process が使うと kill -0 が通る。
# ps が何も返さないときは実行中として扱う (二重実行より skip の方が安全)。
_lock_held() {
  local pid cmd
  pid=$(cat "$LOCK_DIR/pid" 2>/dev/null) || return 1
  case "$pid" in ""|*[!0-9]*|0*|"$$") return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  cmd=$(ps -ww -p "$pid" -o command= 2>/dev/null || true)
  case "$cmd" in
    ""|*daily-research.sh*) return 0 ;;
  esac
  return 1
}

# acquire_lock: 取得成功で 0、実行中の daily-research が保持していて 1、lock を確かめられなくて 2
# (mutex のファイルを開けない・mutex を 10 秒で取れない・python3 の失敗・lock dir を作れない)。2 のときは
# LOCK_ERROR に理由を 1 行で入れる。1 も 2 も run を走らせない側で、呼ぶ側が log と通知の文言を分ける。
# stale な lock は mutex の中で消して取り直す。
# subshell は保持者を確かめたときだけ 10 で終わる。他の非ゼロ (fd 9 の redirect の失敗は bash が 1 を返す)
# は全部 2 に寄せ、確かめていないものを「実行中」と報告しない。
acquire_lock() {
  local rc=0
  LOCK_ERROR=""
  LOCK_ERROR=$(
    (
      _lock_mutex || exit 2
      if _lock_held; then exit 10; fi
      rm -rf "$LOCK_DIR"
      { mkdir "$LOCK_DIR" && echo $$ > "$LOCK_DIR/pid"; } || exit 2
    ) 2>&1 > /dev/null 9>> "$LOCK_DIR.mutex"
  ) || rc=$?
  case "$rc" in
    0) LOCK_ERROR=""; return 0 ;;
    10) LOCK_ERROR=""; return 1 ;;
  esac
  LOCK_ERROR="${LOCK_ERROR//$'\n'/ }"
  [ -n "$LOCK_ERROR" ] || LOCK_ERROR="lock の確認が exit $rc で終わった"
  return 2
}

# release_lock: 自分が保持するロックのみ解放する。常に 0。
# trap EXIT で呼ぶ。stale 奪取後に別プロセスが取り直したロックを誤って消さないよう
# pid ファイルが自分の PID のときだけ削除する。mutex を取れなければ消さずに返す (残った lock は
# 次の取得者が死んだ PID の stale として奪う)。
release_lock() {
  (
    _lock_mutex || exit 0
    if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$LOCK_DIR"; fi
  ) 9>> "$LOCK_DIR.mutex" || true
}
