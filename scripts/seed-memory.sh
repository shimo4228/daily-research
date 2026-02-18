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

# === フラグ解析 ===
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
    *)
      echo "Unknown option: $arg"
      echo "Usage: $0 [--dry-run]"
      exit 1
      ;;
  esac
done

# === 変数 ===
DATE=$(date +%Y-%m-%d)
PROJECT_DIR="$HOME/MyAI_Lab/daily-research"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/$DATE-seed.log"
CONFIG_FILE="$PROJECT_DIR/config.toml"
TIMEOUT_PER_FILE=120  # 1ファイルあたり120秒

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

# === ヘルパー関数 ===

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

notify() {
  local body="${1//\"/}"
  local title="${2//\"/}"
  osascript -e "display notification \"$body\" with title \"$title\"" 2>/dev/null || true
}

# === 設定読み込み ===
if [ ! -f "$CONFIG_FILE" ]; then
  log "ERROR: config.toml not found at $CONFIG_FILE"
  exit 1
fi

VAULT_PATH=$(awk '/^\[general\]/{found=1} found && /^vault_path/{print; exit}' "$CONFIG_FILE" \
  | sed 's/.*= *"//;s/".*//')
OUTPUT_DIR=$(awk '/^\[general\]/{found=1} found && /^output_dir/{print; exit}' "$CONFIG_FILE" \
  | sed 's/.*= *"//;s/".*//')

if [ -z "$VAULT_PATH" ] || [ -z "$OUTPUT_DIR" ]; then
  log "ERROR: vault_path or output_dir not found in config.toml"
  exit 1
fi

REPORT_DIR="$VAULT_PATH/$OUTPUT_DIR"

if [ ! -d "$REPORT_DIR" ]; then
  log "ERROR: Report directory does not exist: $REPORT_DIR"
  exit 1
fi

# interests を config.toml から [user_profile] セクション内で抽出（初期メモリ投入用）
INTERESTS_RAW=$(awk '/^\[user_profile\]/{found=1} found && /^interests/{print; exit}' "$CONFIG_FILE" \
  | sed 's/.*\[//;s/\].*//;s/"//g')
# サニタイズ: 改行・バックスラッシュ・ダブルクォートを除去し200文字に制限
INTERESTS=$(echo "$INTERESTS_RAW" | tr -d '\n"\\' | cut -c1-200)

log "=== Starting seed-memory ==="
log "Report directory: $REPORT_DIR"
log "Dry run: $DRY_RUN"

# === 認証チェック ===
if ! command -v claude &> /dev/null; then
  log "ERROR: claude command not found in PATH"
  notify "claude コマンドが見つかりません" "Seed Memory Error"
  exit 1
fi

if ! claude --version >> "$LOG_FILE" 2>&1; then
  log "ERROR: Claude authentication may have expired"
  notify "Claude認証の更新が必要です" "Seed Memory Auth Error"
  exit 1
fi

# === タイムアウトコマンドの検出 ===
if command -v gtimeout &> /dev/null; then
  TIMEOUT_CMD=(gtimeout "$TIMEOUT_PER_FILE")
elif command -v timeout &> /dev/null; then
  TIMEOUT_CMD=(timeout "$TIMEOUT_PER_FILE")
else
  log "WARN: Neither gtimeout nor timeout found. Running without timeout."
  TIMEOUT_CMD=()
fi

# === レポート列挙 ===
cd "$PROJECT_DIR"

REPORT_FILES=()
while IFS= read -r -d '' file; do
  REPORT_FILES+=("$file")
done < <(find "$REPORT_DIR" -maxdepth 1 -name "*.md" -type f -print0 | gsort -z 2>/dev/null || \
         find "$REPORT_DIR" -maxdepth 1 -name "*.md" -type f -print0)

TOTAL=${#REPORT_FILES[@]}

if [ "$TOTAL" -eq 0 ]; then
  log "No report files found in $REPORT_DIR"
  exit 0
fi

log "Found $TOTAL report files"

# === ドライランモード ===
if [ "$DRY_RUN" = true ]; then
  log "=== DRY RUN: listing files only ==="
  for file in "${REPORT_FILES[@]}"; do
    log "  $(basename "$file")"
  done
  log "=== DRY RUN complete. $TOTAL files would be processed ==="
  exit 0
fi

# === 各レポートの処理 ===
PROCESSED=0
ERRORS=0

for file in "${REPORT_FILES[@]}"; do
  CURRENT=$((PROCESSED + ERRORS + 1))
  BASENAME=$(basename "$file")

  # パス安全チェック: REPORT_DIR 配下のファイルのみ処理
  if [[ "$file" != "$REPORT_DIR"* ]]; then
    log "  WARN: Skipping suspicious path: $file"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  log "[$CURRENT/$TOTAL] Processing: $BASENAME"

  # ファイル名からslugを推測: {date}_{track}_{slug}.md or {date}_{track}_team_{slug}.md
  # 例: 2026-02-18_tech_ai-agent-memory.md → slug=ai-agent-memory
  SLUG=$(echo "$BASENAME" | sed 's/^[0-9-]*_[a-z]*_//;s/^team_//;s/\.md$//')

  PROMPT="以下のレポートファイルを読み込み、Mem0 に記録してください。

ファイルパス: $file

手順:
1. Read ツールでファイルを読む
2. YAML frontmatter から date, category(またはtrack), tags, topic(またはtitle) を抽出する。frontmatter がない場合はファイル名とH1見出しから推測する
3. 本文を2-3文で要約する
4. mcp__mem0__add-memory を呼び出して以下を記録:
   - messages: [{ \"role\": \"user\", \"content\": \"テーマ「{topic}」を調査した。{要約}\" }]
   - user_id: \"daily-research\"
   - metadata: { \"category\": \"topic_history\", \"date\": \"{date}\", \"track\": \"{category/track}\", \"slug\": \"$SLUG\" }
5. 完了したら「OK: ${file}」とだけ出力する。余分な説明は不要"

  # ループ内のエラーでスクリプト全体を止めない
  set +e
  RESULT=$(${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} claude -p "$PROMPT" \
    --allowedTools "Read,mcp__mem0__add-memory,mcp__mem0__search-memories" \
    --max-turns 10 \
    --model sonnet \
    --output-format text \
    --no-session-persistence \
    2>&1)
  FILE_EXIT_CODE=$?
  set -e

  if [ $FILE_EXIT_CODE -eq 0 ] && echo "$RESULT" | grep -q "OK:"; then
    log "  OK"
    PROCESSED=$((PROCESSED + 1))
  elif [ $FILE_EXIT_CODE -eq 124 ]; then
    log "  TIMEOUT (${TIMEOUT_PER_FILE}s): $BASENAME"
    ERRORS=$((ERRORS + 1))
  else
    log "  ERROR (exit $FILE_EXIT_CODE): $BASENAME"
    # エラーの最初の3行をログに記録
    echo "$RESULT" | head -3 >> "$LOG_FILE"
    ERRORS=$((ERRORS + 1))
  fi
done

log "=== Report processing complete: $PROCESSED processed, $ERRORS errors / $TOTAL total ==="

# === 初期メモリの投入 ===
log "=== Registering initial memory entries ==="

SEED_PROMPT="以下の初期データを Mem0 に登録してください。各項目について mcp__mem0__add-memory を呼び出してください。

## 1. research_method カテゴリ（2件）

1件目:
- messages: [{ \"role\": \"user\", \"content\": \"GitHub Trending + 'site:arxiv.org' 検索の組み合わせが、学術×実装の交差点を見つけるのに有効\" }]
- user_id: \"daily-research\"
- metadata: { \"category\": \"research_method\" }

2件目:
- messages: [{ \"role\": \"user\", \"content\": \"Hacker News の Show HN と Ask HN を区別して検索すると、実装事例と議論の両方を効率的に収集できる\" }]
- user_id: \"daily-research\"
- metadata: { \"category\": \"research_method\" }

## 2. source_quality カテゴリ（2件）

1件目:
- messages: [{ \"role\": \"user\", \"content\": \"arxiv + GitHub が一次情報として最も信頼性が高い。VentureBeat は概観に有用だが一次情報に乏しい\" }]
- user_id: \"daily-research\"
- metadata: { \"category\": \"source_quality\" }

2件目:
- messages: [{ \"role\": \"user\", \"content\": \"Semantic Scholar は学術論文の横断検索に有効。被引用数で影響度を判断できる\" }]
- user_id: \"daily-research\"
- metadata: { \"category\": \"source_quality\" }

## 3. user_interest カテゴリ（1件）

- messages: [{ \"role\": \"user\", \"content\": \"${INTERESTS} に継続的関心\" }]
- user_id: \"daily-research\"
- metadata: { \"category\": \"user_interest\" }

全5件の登録が完了したら「OK: initial memory registered」とだけ出力してください。余分な説明は不要です。"

set +e
SEED_RESULT=$(${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} claude -p "$SEED_PROMPT" \
  --allowedTools "Read,mcp__mem0__add-memory,mcp__mem0__search-memories" \
  --max-turns 15 \
  --model sonnet \
  --output-format text \
  --no-session-persistence \
  2>&1)
SEED_EXIT_CODE=$?
set -e

if [ $SEED_EXIT_CODE -eq 0 ] && echo "$SEED_RESULT" | grep -q "OK:"; then
  log "Initial memory entries registered successfully"
else
  log "ERROR: Failed to register initial memory entries (exit $SEED_EXIT_CODE)"
  echo "$SEED_RESULT" | head -5 >> "$LOG_FILE"
  ERRORS=$((ERRORS + 1))
fi

# === サマリー ===
log "=== Seed memory complete ==="
log "  Reports processed: $PROCESSED / $TOTAL"
log "  Errors:            $ERRORS"
log "  Initial memory:    $([ $SEED_EXIT_CODE -eq 0 ] && echo 'OK' || echo 'FAILED')"

# ログファイルの権限を制限
chmod 600 "$LOG_FILE" 2>/dev/null || true

if [ $ERRORS -gt 0 ]; then
  notify "Seed memory 完了（エラー ${ERRORS}件）。ログを確認してください" "Seed Memory"
  exit 1
else
  notify "Seed memory 完了。${PROCESSED}件のレポートを登録しました" "Seed Memory"
  exit 0
fi
