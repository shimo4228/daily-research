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
LOG_FILE="$LOG_DIR/$DATE-team.log"
LOCK_FILE="$PROJECT_DIR/.agent-team-research.lock"
TIMEOUT_SECONDS=2700  # 45分（サブエージェント並列実行を考慮）

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

# === ヘルパー関数 ===

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

notify() {
  local body="${1//\"/}"
  local title="${2//\"/}"
  osascript -e "display notification \"$body\" with title \"$title\"" 2>/dev/null || true
}

# === 同時実行ガード ===
cleanup() {
  rm -f "$LOCK_FILE"
}
trap cleanup EXIT

if [ -f "$LOCK_FILE" ]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log "ERROR: Another instance is running (PID: $LOCK_PID). Skipping."
    notify "前回のチーム版リサーチがまだ実行中です" "Agent Team Research Skipped"
    exit 1
  else
    log "WARN: Stale lock file found, removing"
    rm -f "$LOCK_FILE"
  fi
fi
echo $$ > "$LOCK_FILE"

# === ログローテーション ===
find "$LOG_DIR" -name "*-team.log" -mtime +30 -delete 2>/dev/null || true

log "=== Starting agent team research ==="

# === 認証チェック ===
if ! command -v claude &> /dev/null; then
  log "ERROR: claude command not found in PATH"
  notify "claude コマンドが見つかりません" "Agent Team Research Error"
  exit 1
fi

if ! claude --version >> "$LOG_FILE" 2>&1; then
  log "ERROR: Claude authentication may have expired"
  notify "Claude認証の更新が必要です" "Agent Team Research Auth Error"
  exit 1
fi

# === 実行 ===
cd "$PROJECT_DIR"

# past_topics.json のバックアップ（既存版と別のバックアップ）
if [ -f "$PROJECT_DIR/past_topics.json" ]; then
  cp "$PROJECT_DIR/past_topics.json" "$PROJECT_DIR/past_topics.json.team.bak"
  log "Backed up past_topics.json (team)"
fi

TASK_PROMPT=$(cat prompts/team-task-prompt.md)
if [ -z "$TASK_PROMPT" ]; then
  log "ERROR: prompts/team-task-prompt.md is empty"
  exit 1
fi

log "Executing claude -p with team-orchestrator agent (opus)..."

# タイムアウト付きで実行
if command -v gtimeout &> /dev/null; then
  TIMEOUT_CMD=(gtimeout "$TIMEOUT_SECONDS")
elif command -v timeout &> /dev/null; then
  TIMEOUT_CMD=(timeout "$TIMEOUT_SECONDS")
else
  log "WARN: Neither gtimeout nor timeout found. Running without timeout."
  TIMEOUT_CMD=()
fi

${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} claude -p "$TASK_PROMPT" \
  --agent team-orchestrator \
  --append-system-prompt-file prompts/team-protocol.md \
  --allowedTools "Task,WebSearch,WebFetch,Read,Write,Glob,Grep,mcp__mem0__add-memory,mcp__mem0__search-memories" \
  --max-turns 50 \
  --model opus \
  --output-format json \
  --no-session-persistence \
  >> "$LOG_FILE" 2>&1

EXIT_CODE=$?

# ログファイルの権限を制限
chmod 600 "$LOG_FILE" 2>/dev/null || true

if [ $EXIT_CODE -eq 0 ]; then
  log "=== Agent team research completed successfully ==="
  notify "チーム版リサーチレポートが完成しました" "Agent Team Research"
elif [ $EXIT_CODE -eq 124 ]; then
  log "=== Timed out after ${TIMEOUT_SECONDS}s ==="
  notify "チーム版リサーチがタイムアウトしました (${TIMEOUT_SECONDS}秒)" "Agent Team Research Timeout"
else
  log "=== Failed with exit code $EXIT_CODE ==="
  notify "チーム版リサーチ実行に失敗しました。ログを確認してください。" "Agent Team Research Error"
fi

exit $EXIT_CODE
