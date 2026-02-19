#!/usr/bin/env bats
# E2E tests with mock claude command
# Run: bats tests/test-e2e-mock.bats
#
# mock claude を $MOCK_HOME/.claude/local/ に配置し、
# daily-research.sh の PATH 優先ロジックで本物より先に見つかるようにする。
# HOME を差し替えることで本番環境に影響を与えない。

REAL_PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# === Setup / Teardown ===

setup() {
  MOCK_HOME="$(mktemp -d)"
  MOCK_PROJECT="$MOCK_HOME/MyAI_Lab/daily-research"

  # プロジェクト構造を再現
  mkdir -p "$MOCK_PROJECT/scripts"
  mkdir -p "$MOCK_PROJECT/prompts"
  mkdir -p "$MOCK_PROJECT/templates"
  mkdir -p "$MOCK_PROJECT/logs"

  # スクリプト・プロンプト・テンプレートをコピー
  cp "$REAL_PROJECT_DIR/scripts/daily-research.sh" "$MOCK_PROJECT/scripts/"
  cp "$REAL_PROJECT_DIR/prompts/theme-selection-prompt.md" "$MOCK_PROJECT/prompts/"
  cp "$REAL_PROJECT_DIR/prompts/task-prompt.md" "$MOCK_PROJECT/prompts/"
  cp "$REAL_PROJECT_DIR/prompts/research-protocol.md" "$MOCK_PROJECT/prompts/"
  cp "$REAL_PROJECT_DIR/templates/report-template.md" "$MOCK_PROJECT/templates/"

  # config.toml のミニマル版（vault_path を temp に向ける）
  cat > "$MOCK_PROJECT/config.toml" << 'EOF'
[general]
vault_path = "/tmp/mock-vault"

[tracks]
tech = "テクノロジー"
personal = "パーソナル"
EOF

  # past_topics.json のミニマル版
  cat > "$MOCK_PROJECT/past_topics.json" << 'EOF'
{
  "topics": []
}
EOF

  # mock claude を配置（スクリプトが $HOME/.claude/local を PATH に追加する）
  mkdir -p "$MOCK_HOME/.claude/local"

  # mock の挙動は MOCK_SCENARIO ファイルで制御
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  create_mock_claude
}

teardown() {
  rm -rf "$MOCK_HOME"
}

# === Mock claude generator ===

create_mock_claude() {
  cat > "$MOCK_HOME/.claude/local/claude" << 'MOCK_SCRIPT'
#!/bin/bash
# Mock claude for E2E testing
MOCK_HOME_DIR="$(dirname "$(dirname "$(dirname "$0")")")"
SCENARIO=$(cat "$MOCK_HOME_DIR/.mock_scenario" 2>/dev/null || echo "normal")

# --version check
if [[ "$1" == "--version" ]]; then
  echo "2.1.47 (Claude Code - Mock)"
  exit 0
fi

# Parse --model flag
MODEL=""
PREV=""
for arg in "$@"; do
  if [[ "$PREV" == "--model" ]]; then
    MODEL="$arg"
  fi
  PREV="$arg"
done

# --- Opus (Pass 1: theme selection) ---
if [[ "$MODEL" == "opus" ]]; then
  case "$SCENARIO" in
    normal)
      cat << 'JSON'
{
  "themes": [
    {
      "track": "tech",
      "topic": "Mock Tech Topic for E2E Testing",
      "slug": "mock-tech-topic",
      "score": 85,
      "rationale": "E2E test rationale"
    },
    {
      "track": "personal",
      "topic": "Mock Personal Topic for E2E Testing",
      "slug": "mock-personal-topic",
      "score": 80,
      "rationale": "E2E test rationale"
    }
  ]
}
JSON
      exit 0
      ;;
    pass1-fail)
      echo "ERROR: Simulated Pass 1 failure" >&2
      exit 1
      ;;
    pass1-bad-json)
      echo "This is not valid JSON at all"
      exit 0
      ;;
  esac
fi

# --- Sonnet (Pass 2: research & writing) ---
if [[ "$MODEL" == "sonnet" ]]; then
  # 受け取ったプロンプトをファイルに記録（テストで検証用）
  PREV=""
  for arg in "$@"; do
    if [[ "$PREV" == "-p" ]]; then
      echo "$arg" > "$MOCK_HOME_DIR/.sonnet_prompt"
    fi
    PREV="$arg"
  done

  echo '{"type":"result","subtype":"success","is_error":false,"duration_ms":100}'
  exit 0
fi

echo "Unknown model: $MODEL" >&2
exit 1
MOCK_SCRIPT
  chmod +x "$MOCK_HOME/.claude/local/claude"
}

# === Helper ===

run_script() {
  HOME="$MOCK_HOME" bash "$MOCK_PROJECT/scripts/daily-research.sh" 2>&1
}

get_log() {
  cat "$MOCK_PROJECT/logs/$(date +%Y-%m-%d).log"
}

# === Test: Normal path (Opus → Sonnet) ===

@test "E2E normal: Opus theme selection → Sonnet research" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run_script
  local log_content
  log_content=$(get_log)

  # Pass 1 成功
  echo "$log_content" | grep -q "Pass 1 completed: themes selected by Opus"

  # Pass 2 実行
  echo "$log_content" | grep -q "Pass 2: Research & writing (Sonnet)"

  # 成功完了
  echo "$log_content" | grep -q "Completed successfully"

  # CLAUDE_CMD がログに記録されている
  echo "$log_content" | grep -q "DEBUG: CLAUDE_CMD="
}

@test "E2E normal: Sonnet receives theme JSON in prompt" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run_script

  # Sonnet に渡されたプロンプトにテーマ JSON が含まれる
  local sonnet_prompt
  sonnet_prompt=$(cat "$MOCK_HOME/.sonnet_prompt")

  echo "$sonnet_prompt" | grep -q "mock-tech-topic"
  echo "$sonnet_prompt" | grep -q "mock-personal-topic"
  echo "$sonnet_prompt" | grep -q "選定済みテーマ"
}

# === Test: Pass 1 failure fallback ===

@test "E2E fallback: Pass 1 failure triggers Sonnet fallback" {
  echo "pass1-fail" > "$MOCK_HOME/.mock_scenario"

  run_script
  local log_content
  log_content=$(get_log)

  # フォールバック警告
  echo "$log_content" | grep -q "WARN: Pass 1 failed"
  echo "$log_content" | grep -q "falling back to Sonnet"

  # Sonnet フォールバック実行
  echo "$log_content" | grep -q "Fallback: Sonnet handles theme selection + research"

  # Pass 2 は実行される（exit していない）
  echo "$log_content" | grep -q "Pass 2: Research & writing (Sonnet)"

  # 成功完了
  echo "$log_content" | grep -q "Completed successfully"
}

@test "E2E fallback: Sonnet fallback prompt includes theme selection step" {
  echo "pass1-fail" > "$MOCK_HOME/.mock_scenario"

  run_script

  local sonnet_prompt
  sonnet_prompt=$(cat "$MOCK_HOME/.sonnet_prompt")

  # フォールバック時はテーマ選定ステップが含まれる
  echo "$sonnet_prompt" | grep -q "テーマを選定する"

  # 選定済みテーマ セクションは含まれない
  ! echo "$sonnet_prompt" | grep -q "選定済みテーマ"
}

# === Test: JSON validation failure fallback ===

@test "E2E fallback: Bad JSON triggers Sonnet fallback" {
  echo "pass1-bad-json" > "$MOCK_HOME/.mock_scenario"

  run_script
  local log_content
  log_content=$(get_log)

  # JSON バリデーション失敗
  echo "$log_content" | grep -q "WARN: Pass 1 output failed JSON validation"
  echo "$log_content" | grep -q "falling back to Sonnet"

  # Sonnet フォールバック実行
  echo "$log_content" | grep -q "Fallback: Sonnet handles theme selection + research"

  # 成功完了
  echo "$log_content" | grep -q "Completed successfully"
}

# === Test: Absolute path resolution ===

@test "E2E: CLAUDE_CMD resolves to absolute path in .claude/local" {
  echo "normal" > "$MOCK_HOME/.mock_scenario"

  run_script
  local log_content
  log_content=$(get_log)

  # CLAUDE_CMD が .claude/local のパスに解決されている
  echo "$log_content" | grep -q "DEBUG: CLAUDE_CMD=$MOCK_HOME/.claude/local/claude"
}

# === Test: No gtimeout dependency ===

@test "E2E: script does not invoke gtimeout/timeout commands" {
  # gtimeout/timeout はプロセスグループ分離で claude を停止させるため不使用
  # コメント行を除外して、実行コードに gtimeout/TIMEOUT_CMD がないことを確認
  ! grep -v '^#\|^[[:space:]]*#' "$MOCK_PROJECT/scripts/daily-research.sh" | grep -q 'gtimeout\|TIMEOUT_CMD\|timeout_secs'
}
