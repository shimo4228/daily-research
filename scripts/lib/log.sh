#!/usr/bin/env bash
# log.sh — ロギング。LOG_DIR / LOG_FILE を呼び出し側で定義済みであること。source 専用。

# ログ環境を初期化する。
# - logs/ とログファイルを作成し、権限を「作成時に」制限する (旧実装は実行末尾で chmod
#   していたため、実行中はログが group/other に読めた = ctl-012)
# - 30 日より古いログを削除 (ローテーション)
log_init() {
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  : >> "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null || true
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}
