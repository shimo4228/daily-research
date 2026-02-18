#!/usr/bin/env bats
# Tests for agent team research
# Run: bats tests/test-agent-team.bats

# テストファイルからの相対パスでプロジェクトルートを解決
PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
TEAM_SCRIPT="$PROJECT_DIR/scripts/agent-team-research.sh"
AGENTS_DIR="$PROJECT_DIR/.claude/agents"

# === Setup / Teardown ===

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# === Syntax checks ===

@test "agent-team-research.sh has valid syntax" {
  bash -n "$TEAM_SCRIPT"
}

# === Agent definition files ===

@test "team-orchestrator.md exists" {
  [ -f "$AGENTS_DIR/team-orchestrator.md" ]
}

@test "team-researcher.md exists" {
  [ -f "$AGENTS_DIR/team-researcher.md" ]
}

@test "team-writer.md exists" {
  [ -f "$AGENTS_DIR/team-writer.md" ]
}

# === Prompt files ===

@test "team-task-prompt.md exists" {
  [ -f "$PROJECT_DIR/prompts/team-task-prompt.md" ]
}

@test "team-protocol.md exists" {
  [ -f "$PROJECT_DIR/prompts/team-protocol.md" ]
}

# === Security checks ===

@test "team script unsets ANTHROPIC_API_KEY" {
  grep -q "unset ANTHROPIC_API_KEY" "$TEAM_SCRIPT"
}

@test "no hardcoded API keys in team script" {
  ! grep -qE '(sk-[a-zA-Z0-9]{20,}|api_key\s*=\s*"[^"]+")' "$TEAM_SCRIPT"
}

@test "team log file permissions are restricted (chmod 600)" {
  grep -q 'chmod 600 "$LOG_FILE"' "$TEAM_SCRIPT"
}

# === Defensive programming ===

@test "team script uses set -euo pipefail" {
  head -3 "$TEAM_SCRIPT" | grep -q "set -euo pipefail"
}

@test "team script has trap cleanup on EXIT" {
  grep -q 'trap cleanup EXIT' "$TEAM_SCRIPT"
}

@test "team script has timeout configured" {
  grep -q 'TIMEOUT_SECONDS=' "$TEAM_SCRIPT"
}

# === Lock file isolation ===

@test "team script uses separate lock file" {
  grep -q '.agent-team-research.lock' "$TEAM_SCRIPT"
}

@test "team lock file is different from main lock file" {
  local main_lock team_lock
  main_lock=$(grep 'LOCK_FILE=' "$PROJECT_DIR/scripts/daily-research.sh" | head -1)
  team_lock=$(grep 'LOCK_FILE=' "$TEAM_SCRIPT" | head -1)
  [ "$main_lock" != "$team_lock" ]
}

# === Log file isolation ===

@test "team script uses separate log file" {
  grep -q 'team.log' "$TEAM_SCRIPT"
}

# === Claude CLI flags ===

@test "team script uses --agent team-orchestrator" {
  grep -q '\-\-agent team-orchestrator' "$TEAM_SCRIPT"
}

@test "team script includes Task in allowedTools" {
  grep -q 'Task' "$TEAM_SCRIPT"
}

@test "team script uses opus model" {
  grep -q '\-\-model opus' "$TEAM_SCRIPT"
}

@test "team script uses --no-session-persistence" {
  grep -q '\-\-no-session-persistence' "$TEAM_SCRIPT"
}

# === Chain execution ===

@test "daily-research.sh chains to agent-team-research.sh" {
  grep -q 'agent-team-research.sh' "$PROJECT_DIR/scripts/daily-research.sh"
}

@test "chain execution is isolated (failure does not affect exit code)" {
  # The chain uses || to isolate failures
  grep -q '|| log "WARN:' "$PROJECT_DIR/scripts/daily-research.sh"
}

@test "chain only runs if main pipeline succeeds" {
  grep -q 'EXIT_CODE -eq 0.*TEAM_SCRIPT' "$PROJECT_DIR/scripts/daily-research.sh"
}

# === Agent content checks ===

@test "orchestrator agent mentions team-researcher" {
  grep -q 'team-researcher' "$AGENTS_DIR/team-orchestrator.md"
}

@test "orchestrator agent mentions team-writer" {
  grep -q 'team-writer' "$AGENTS_DIR/team-orchestrator.md"
}

@test "researcher agent limits output to 2000 chars" {
  grep -q '2000' "$AGENTS_DIR/team-researcher.md"
}

@test "writer agent saves to vault directly" {
  grep -q 'Write' "$AGENTS_DIR/team-writer.md"
}
