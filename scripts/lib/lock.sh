#!/usr/bin/env bash
# lock.sh — mkdir ベースのアトミックな同時実行ロック。source 専用。
# LOCK_DIR を呼び出し側で定義済みであること (ロックはディレクトリとして扱う)。
#
# 旧実装は `[ -f lock ]` で確認してから `echo $$ > lock` で書き込む check-then-write
# で、確認と書き込みの間に他プロセスが割り込む race があった (ctl-014)。
# mkdir はアトミック (既存なら必ず失敗する) なので、これでロック取得を不可分にする。

# acquire_lock: 取得成功で 0、他インスタンス実行中で 1。
# 既存ロックの PID が死んでいれば stale とみなして奪取する。
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    return 0
  fi
  # 既存ロックあり: PID で stale 判定
  local pid
  pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1  # 実行中
  fi
  # stale ロック: 奪取を試みる
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
