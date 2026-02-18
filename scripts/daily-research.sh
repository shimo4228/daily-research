#!/bin/bash
set -euo pipefail

# === 環境サニタイズ ===
# APIキーが設定されていると従量課金になるため確実に除去
unset ANTHROPIC_API_KEY

# launchd環境はPATHが最小限。必要なパスを明示的に設定
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
# claude コマンドのパスを直接確認して追加
if [ -d "$HOME/.claude/local" ]; then
  export PATH="$HOME/.claude/local:$PATH"
fi

# === 変数 ===
DATE=$(date +%Y-%m-%d)
PROJECT_DIR="$HOME/MyAI_Lab/daily-research"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/$DATE.log"
LOCK_FILE="$PROJECT_DIR/.daily-research.lock"
TIMEOUT_SECONDS=1800  # 30分

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

# === ヘルパー関数 ===

# [HIGH-1] タイムスタンプを毎回取得
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# [HIGH-3] osascript が失敗してもスクリプトを中断しない
notify() {
  osascript -e "display notification \"$1\" with title \"$2\"" 2>/dev/null || true
}

# === 同時実行ガード [HIGH-2] ===
cleanup() {
  rm -f "$LOCK_FILE"
}
trap cleanup EXIT

if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "ERROR: Another instance is running (PID: $LOCK_PID). Skipping."
    notify "前回のリサーチがまだ実行中です" "Daily Research Skipped"
    exit 1
  else
    log "WARN: Stale lock file found, removing"
    rm -f "$LOCK_FILE"
  fi
fi
echo $$ > "$LOCK_FILE"

# === ログローテーション [HIGH-4] ===
find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null || true

log "=== Starting daily research ==="

# === 認証チェック ===
if ! command -v claude &> /dev/null; then
  log "ERROR: claude command not found in PATH"
  notify "claude コマンドが見つかりません" "Daily Research Error"
  exit 1
fi

# Claude OAuth認証状態チェック（claude --version が通るか）
if ! claude --version >> "$LOG_FILE" 2>&1; then
  log "ERROR: Claude authentication may have expired"
  notify "Claude認証の更新が必要です。claude を起動してください。" "Daily Research Auth Error"
  exit 1
fi

# === 実行 ===
cd "$PROJECT_DIR"

# [MEDIUM-1] past_topics.json のバックアップ
if [ -f "$PROJECT_DIR/past_topics.json" ]; then
  cp "$PROJECT_DIR/past_topics.json" "$PROJECT_DIR/past_topics.json.bak"
  log "Backed up past_topics.json"
fi

TASK_PROMPT=$(cat prompts/task-prompt.md)

log "Executing claude -p with sonnet model..."

# [MEDIUM-2] タイムアウト付きで実行
if command -v gtimeout &> /dev/null; then
  TIMEOUT_CMD="gtimeout $TIMEOUT_SECONDS"
elif command -v timeout &> /dev/null; then
  TIMEOUT_CMD="timeout $TIMEOUT_SECONDS"
else
  TIMEOUT_CMD=""
fi

$TIMEOUT_CMD claude -p "$TASK_PROMPT" \
  --append-system-prompt-file prompts/research-protocol.md \
  --allowedTools "WebSearch,WebFetch,Read,Write,Glob,Grep" \
  --max-turns 40 \
  --model sonnet \
  --output-format json \
  --no-session-persistence \
  >> "$LOG_FILE" 2>&1

EXIT_CODE=$?

# [MEDIUM-3] ログファイルの権限を制限
chmod 600 "$LOG_FILE" 2>/dev/null || true

if [ $EXIT_CODE -eq 0 ]; then
  log "=== Completed successfully ==="
  notify "今朝のリサーチレポートが完成しました" "Daily Research"
elif [ $EXIT_CODE -eq 124 ]; then
  log "=== Timed out after ${TIMEOUT_SECONDS}s ==="
  notify "リサーチがタイムアウトしました (${TIMEOUT_SECONDS}秒)" "Daily Research Timeout"
else
  log "=== Failed with exit code $EXIT_CODE ==="
  notify "リサーチ実行に失敗しました。ログを確認してください。" "Daily Research Error"
fi

# === エージェントチーム版のチェーン実行 ===
# チーム版スクリプトの存在自体がフィーチャーフラグ
# チーム版の失敗は既存パイプラインの終了コードに影響しない
TEAM_SCRIPT="$PROJECT_DIR/scripts/agent-team-research.sh"
if [ $EXIT_CODE -eq 0 ] && [ -x "$TEAM_SCRIPT" ]; then
  log "=== Chaining agent team research ==="
  "$TEAM_SCRIPT" || log "WARN: Agent team research failed (exit $?), continuing"
fi

exit $EXIT_CODE
