#!/usr/bin/env bash
# pre-commit hook for daily-research
#
# Install:
#   ln -sf ../../scripts/pre-commit.sh .git/hooks/pre-commit
#
# What it checks:
#   1. Secrets: API keys, personal paths in staged files
#   2. Gitignore: Secret files not accidentally tracked
#   3. Syntax: bash -n on staged .sh files

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

errors=0

# --- 1. Secret detection ---
# Patterns that should never appear in committed files
secret_patterns=(
  'MEM0_API_KEY=\S'          # Hardcoded Mem0 key (not just the variable name)
  'ANTHROPIC_API_KEY=\S'     # Hardcoded Anthropic key
  'sk-proj-'                 # OpenAI API key prefix
  'sk-ant-'                  # Anthropic API key prefix
  'iCloud~md~obsidian'       # Personal Obsidian vault path
)

# Files excluded from secret scanning (this hook defines patterns, not secrets)
scan_exclude="scripts/pre-commit.sh"

# NUL 区切り + read -d '' で空白・非 ASCII のパスも 1 要素として扱う。unquoted 展開で
# 語分割すると `my notes.md` は 2 片に、日本語名は core.quotePath の "\350\250..." に
# なり、どちらも `git diff -- "$f"` が空を返して走査されない (2026-08-22 review、PoC 済み)
staged_files=()
while IFS= read -r -d '' f; do
  staged_files+=("$f")
done < <(git diff --cached --name-only --diff-filter=ACM -z)

if [ ${#staged_files[@]} -gt 0 ]; then
  for pattern in "${secret_patterns[@]}"; do
    # Search staged content per-file, skipping excluded files
    for f in "${staged_files[@]}"; do
      case "$f" in "$scan_exclude") continue ;; esac
      matches=$(git diff --cached -U0 -- "$f" | grep -E "^\+" | grep -E "$pattern" || true)
      if [ -n "$matches" ]; then
        echo -e "${RED}[BLOCKED] Secret pattern in ${f}: ${pattern}${NC}"
        echo "$matches" | head -3
        errors=$((errors + 1))
      fi
    done
  done
fi

# --- 2. Gitignore consistency ---
# These files must never be tracked
protected_files=(
  config.toml
  .mcp.json
  past_topics.json
)

for f in "${protected_files[@]}"; do
  if git ls-files --cached --error-unmatch "$f" >/dev/null 2>&1; then
    echo -e "${RED}[BLOCKED] Protected file is tracked by git: ${f}${NC}"
    echo "  Run: git rm --cached $f"
    errors=$((errors + 1))
  fi
done

# --- 3. Shell script syntax check ---
syntax_err=$(mktemp "${TMPDIR:-/tmp}/pre-commit-syntax.XXXXXX")
trap 'rm -f "$syntax_err"' EXIT

for f in "${staged_files[@]}"; do
  case "$f" in *.sh) ;; *) continue ;; esac
  if [ -f "$f" ]; then
    if ! bash -n "$f" 2>"$syntax_err"; then
      echo -e "${RED}[BLOCKED] Syntax error in ${f}:${NC}"
      cat "$syntax_err"
      errors=$((errors + 1))
    fi
  fi
done

# --- Result ---
if [ "$errors" -gt 0 ]; then
  echo ""
  echo -e "${RED}Pre-commit: ${errors} issue(s) found. Commit blocked.${NC}"
  exit 1
fi

echo -e "${GREEN}Pre-commit: all checks passed.${NC}"
exit 0
