#!/usr/bin/env bash
# lock.sh — mkdir ベースのアトミックな同時実行ロック。source 専用。
# LOCK_DIR を呼び出し側で定義済みであること (ロックはディレクトリとして扱う)。
#
# 旧実装は `[ -f lock ]` で確認してから `echo $$ > lock` で書き込む check-then-write
# で、確認と書き込みの間に他プロセスが割り込む race があった (ctl-014)。
# mkdir はアトミック (既存なら必ず失敗する) なので、これでロック取得を不可分にする。

# acquire_lock: 取得成功で 0、他インスタンス実行中で 1。
# 既存ロックの PID が死んでいれば stale とみなして奪取する。PID が生きていても、その process の
# コマンド行が daily-research.sh でないと読めたときは stale とみなす — run 中の再起動で lock dir が
# 残り、再起動後に同じ PID を別の process が使うと kill -0 が通り、以後の run が全部 skip になる。
# ps が何も返さないときは実行中として扱う (二重実行より skip の方が安全)。
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    return 0
  fi
  # 既存ロックあり: PID で stale 判定
  local pid cmd
  pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    cmd=$(ps -ww -p "$pid" -o command= 2>/dev/null || true)
    case "$cmd" in
      ""|*daily-research.sh*) return 1 ;;  # 実行中
    esac
  fi
  # stale ロック: 奪取を試みる。
  # 保証の範囲: mkdir の原子性が守るのは 1 回の mkdir の勝者が 1 つであることだけで、奪取は不可分でない。
  # 2 プロセスが同じ stale lock をほぼ同時に見つけると、先に rm→mkdir した側の新しい lock を遅れた側の
  # rm -rf が消し、遅れた側の mkdir も成功して両方が走る (pid は後の側。先の側の run スコープの基準
  # $LOCK_DIR/pid の mtime も後の側の時刻に変わる)。起きうるのは stale lock が残った朝に launchd の起動と
  # 手動実行・試験 seam の run が重なったとき。不可分な奪取が要るなら mv -n 等で作り直す。
  rm -rf "$LOCK_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    return 0
  fi
  return 1
}

# release_lock: 自分が保持するロックのみ解放する。
# trap EXIT で呼ぶ。stale 奪取後に別プロセスが取り直したロックを誤って消さないよう
# pid ファイルが自分の PID のときだけ削除する。
release_lock() {
  if [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$LOCK_DIR"
  fi
}
