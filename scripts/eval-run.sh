#!/bin/bash
set -euo pipefail

# === 環境サニタイズ ===
unset ANTHROPIC_API_KEY
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ -d "$HOME/.claude/local" ]; then
  export PATH="$HOME/.claude/local:$PATH"
fi

# === 変数 ===
DATE="${1:-$(date +%Y-%m-%d)}"
PROJECT_DIR="$HOME/MyAI_Lab/daily-research"
PROMPTS_DIR="$PROJECT_DIR/evals/prompts"
SCORES_FILE="$PROJECT_DIR/evals/scores.jsonl"
PIPELINE_VERSION="2pass-opus-sonnet"
JUDGE_MODEL="claude-opus-4-6"

LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/$DATE.log"
mkdir -p "$LOG_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [eval] $1" >> "$LOG_FILE"
}

# === claude コマンド確認 ===
if ! command -v claude &>/dev/null; then
  log "ERROR: claude command not found"
  exit 1
fi
CLAUDE_CMD=$(command -v claude)

# === config.toml から vault_path / output_dir を読み込む ===
VAULT_PATH=$(python3 -c "
import re
with open('$PROJECT_DIR/config.toml') as f:
    content = f.read()
m = re.search(r'vault_path\s*=\s*\"([^\"]+)\"', content)
if not m:
    raise ValueError('vault_path not found in config.toml')
print(m.group(1))
") || { log "ERROR: Failed to read vault_path from config.toml"; exit 1; }

OUTPUT_DIR=$(python3 -c "
import re
with open('$PROJECT_DIR/config.toml') as f:
    content = f.read()
m = re.search(r'output_dir\s*=\s*\"([^\"]+)\"', content)
print(m.group(1) if m else 'daily-research')
")

REPORT_DIR="${VAULT_PATH}/${OUTPUT_DIR}"

log "=== Evaluation start: DATE=${DATE} ==="
log "Report dir: ${REPORT_DIR}"

# === 当日レポートを探す ===
REPORTS=()
while IFS= read -r -d '' f; do
  REPORTS+=("$f")
done < <(find "$REPORT_DIR" -maxdepth 1 -name "${DATE}_*.md" -print0 2>/dev/null || true)

if [ ${#REPORTS[@]} -eq 0 ]; then
  log "WARN: No reports found for ${DATE} in ${REPORT_DIR}"
  exit 0
fi

log "Found ${#REPORTS[@]} report(s)"

# === 評価次元 ===
DIMENSIONS=("factual" "depth" "coherence" "specificity" "novelty" "actionability")
DIMENSION_KEYS=("factual_grounding" "depth_of_analysis" "coherence" "specificity" "novelty" "actionability")

# === 各レポートを評価 ===
for report_file in "${REPORTS[@]}"; do
  filename=$(basename "$report_file")

  # ファイル名解析: YYYY-MM-DD_track_slug.md
  # 例: 2026-02-21_tech_xcode-26-agentic-coding-mcp.md
  TRACK_PART=$(python3 -c "
import sys, re
name = sys.argv[1]
m = re.match(r'^\d{4}-\d{2}-\d{2}_([^_]+)_(.+)\.md$', name)
if not m:
    raise ValueError(f'Unexpected filename format: {name}')
print(m.group(1))
" "$filename" 2>>"$LOG_FILE") || { log "ERROR: Cannot parse filename: $filename"; continue; }

  SLUG_PART=$(python3 -c "
import sys, re
name = sys.argv[1]
m = re.match(r'^\d{4}-\d{2}-\d{2}_([^_]+)_(.+)\.md$', name)
if not m:
    raise ValueError(f'Unexpected filename format: {name}')
print(m.group(2))
" "$filename" 2>>"$LOG_FILE") || { log "ERROR: Cannot parse filename: $filename"; continue; }

  log "Evaluating: ${filename} (track=${TRACK_PART} slug=${SLUG_PART})"

  EVAL_START=$(date +%s)
  EVAL_OK=true

  # スコアを一時ファイルに蓄積
  SCORES_TEMP=$(mktemp)
  trap 'rm -f "$SCORES_TEMP"' EXIT

  for i in "${!DIMENSIONS[@]}"; do
    dim="${DIMENSIONS[$i]}"
    dim_key="${DIMENSION_KEYS[$i]}"

    # 次元プロンプトにレポート本文を注入（python3 で安全に置換）
    FULL_PROMPT=$(python3 -c "
import sys
template = open(sys.argv[1]).read()
article = open(sys.argv[2]).read()
print(template.replace('{ARTICLE_CONTENT}', article))
" "$PROMPTS_DIR/judge-${dim}.md" "$report_file" 2>>"$LOG_FILE") || {
      log "  ERROR: Failed to build prompt for ${dim_key}"
      EVAL_OK=false
      break
    }

    log "  Judging: ${dim_key}"

    # Judge 実行
    JUDGE_JSON=""
    JUDGE_EXIT=0
    JUDGE_JSON=$("$CLAUDE_CMD" -p "$FULL_PROMPT" \
      --append-system-prompt-file "$PROMPTS_DIR/judge-system.md" \
      --max-turns 3 \
      --model "$JUDGE_MODEL" \
      --output-format json \
      --no-session-persistence \
      2>>"$LOG_FILE") || JUDGE_EXIT=$?

    if [ $JUDGE_EXIT -ne 0 ] || [ -z "$JUDGE_JSON" ]; then
      log "  ERROR: Judge failed for ${dim_key} (exit=${JUDGE_EXIT})"
      EVAL_OK=false
      break
    fi

    # スコア抽出（フォールバック付き）
    SCORE=$(python3 -c "
import sys, json, re
outer = json.loads(sys.argv[1])
result_text = outer.get('result', '').strip()

# マークダウンコードフェンスを除去
result_text = re.sub(r'^\`\`\`(?:json)?\s*', '', result_text)
result_text = re.sub(r'\s*\`\`\`\s*$', '', result_text).strip()

# 1. まず直接 JSON パースを試みる
score = None
try:
    inner = json.loads(result_text)
    score = int(inner.get('score', 0))
except (json.JSONDecodeError, ValueError):
    pass

# 2. フォールバック: 'score' キーを正規表現で抽出（rationale に {} が含まれる場合に対応）
if score is None:
    m = re.search(r'\"score\"\s*:\s*(\d+)', result_text)
    if not m:
        print(f'Cannot extract score from: {result_text[:200]}', file=sys.stderr)
        sys.exit(1)
    score = int(m.group(1))

if not (1 <= score <= 5):
    print(f'Score out of range: {score}', file=sys.stderr)
    sys.exit(1)
print(score)
" "$JUDGE_JSON" 2>>"$LOG_FILE") || {
      log "  ERROR: Score parse failed for ${dim_key}"
      EVAL_OK=false
      break
    }

    log "  ${dim_key}: ${SCORE}"
    echo "${dim_key}=${SCORE}" >> "$SCORES_TEMP"
  done

  if [ "$EVAL_OK" = true ]; then
    EVAL_END=$(date +%s)
    EVAL_DURATION=$((EVAL_END - EVAL_START))

    # JSONL エントリを生成して追記
    ENTRY=$(python3 -c "
import json, sys

scores = {}
total = 0
with open(sys.argv[1]) as f:
    for line in f:
        k, v = line.strip().split('=', 1)
        scores[k] = int(v)
        total += int(v)

entry = {
    'date': sys.argv[2],
    'pipeline_version': sys.argv[3],
    'track': sys.argv[4],
    'slug': sys.argv[5],
    'scores': scores,
    'total': total,
    'judge_model': sys.argv[6],
    'eval_duration_s': int(sys.argv[7])
}
print(json.dumps(entry, ensure_ascii=False))
" "$SCORES_TEMP" "$DATE" "$PIPELINE_VERSION" "$TRACK_PART" "$SLUG_PART" "$JUDGE_MODEL" "$EVAL_DURATION" 2>>"$LOG_FILE") || {
      log "  ERROR: Failed to build JSONL entry"
      rm -f "$SCORES_TEMP"
      continue
    }

    echo "$ENTRY" >> "$SCORES_FILE"
    TOTAL=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['total'])" "$ENTRY")
    log "  Saved: total=${TOTAL}/30 duration=${EVAL_DURATION}s"
  else
    log "  WARN: Evaluation incomplete for ${filename}, not saving"
  fi

  rm -f "$SCORES_TEMP"
  trap - EXIT
done

log "=== Evaluation done ==="
