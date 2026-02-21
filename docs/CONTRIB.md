# Contributing / Development Guide

> Source of truth: `config.example.toml`, `scripts/*.sh`, `com.example.daily-research.plist`

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| Claude Code CLI | Core execution engine | `brew install claude` or [docs.anthropic.com](https://docs.anthropic.com) |
| Claude Max plan | Zero-cost API usage | Subscription required |
| macOS (launchd) | Scheduler | Built-in |
| python3 | JSON schema validation (Pass 1 output) | Pre-installed on macOS |
| bats-core | Shell test framework | `brew install bats-core` |
| shellcheck | Shell linting | `brew install shellcheck` |

## Project Structure

```
daily-research/
├── config.example.toml                  # Research tracks, scoring, output settings (template)
├── past_topics.json                     # Topic history (deduplication, gitignored)
├── prompts/
│   ├── theme-selection-prompt.md       # Pass 1: Theme selection instruction (Opus)
│   ├── task-prompt.md                   # Pass 2: Research instruction (Sonnet)
│   └── research-protocol.md            # Pass 2: Research protocol (--append-system-prompt-file)
├── templates/
│   └── report-template.md              # Obsidian report format with frontmatter
├── scripts/
│   ├── daily-research.sh               # Main entry point (2-pass: Opus → Sonnet)
│   ├── eval-run.sh                      # LLM-as-Judge evaluation (post Pass 2)
│   └── check-auth.sh                   # OAuth authentication check + notification
├── evals/
│   ├── prompts/                         # Judge prompts (judge-system.md + 6 dimensions)
│   │   ├── judge-system.md             # Shared system prompt (bias mitigation, output format)
│   │   ├── judge-factual.md            # Factual Grounding rubric
│   │   ├── judge-depth.md              # Depth of Analysis rubric
│   │   ├── judge-coherence.md          # Coherence rubric
│   │   ├── judge-specificity.md        # Specificity rubric
│   │   ├── judge-novelty.md            # Novelty rubric
│   │   └── judge-actionability.md      # Actionability rubric
│   ├── scores.jsonl                     # Score log (append-only, gitignored)
│   └── scores.example.jsonl            # Schema reference sample (Git tracked)
├── com.example.daily-research.plist   # launchd schedule (AM 5:00)
├── tests/
│   ├── test-daily-research.bats        # Unit tests (syntax, config, security)
│   ├── test-e2e-mock.bats             # E2E mock tests
│   └── test-eval.bats                  # Evaluation framework tests
├── logs/                                # Execution logs (date-stamped, auto-rotated 30d)
├── docs/
│   ├── RUNBOOK.md / RUNBOOK.ja.md      # Operations guide
│   ├── CONTRIB.md / CONTRIB.ja.md      # Development guide (this file)
│   ├── MEM0-RESTORE.md                 # Mem0 restoration procedure
│   ├── plans/                           # Future expansion plans
│   └── progress/                        # Postmortems and evaluation reports
└── .claude/settings.local.json          # Claude Code project permissions
```

## Scripts Reference

| Script | Description | Usage |
|--------|-------------|-------|
| `scripts/daily-research.sh` | Main entry point. 2-pass execution: Pass 1 (Opus theme selection) → Pass 2 (Sonnet research & writing). Includes env sanitization, auth check, JSON validation, Sonnet fallback, and post-run evaluation hook. Called by launchd at AM 5:00. | `./scripts/daily-research.sh` |
| `scripts/eval-run.sh` | LLM-as-Judge evaluation. Scores each report on 6 dimensions (1-5 scale) using Opus. Called automatically after Pass 2 success. Non-fatal: failures do not affect the main exit code. | `./scripts/eval-run.sh 2026-02-21` |
| `scripts/check-auth.sh` | Checks Claude OAuth token validity via `claude --version`. Shows macOS notification on failure. | `./scripts/check-auth.sh` |

## Environment Variables

| Variable | Source | Purpose |
|----------|--------|---------|
| `PATH` | plist + script | Must include `/opt/homebrew/bin`, `/usr/local/bin`, `$HOME/.claude/local` |
| `HOME` | plist | Required for Claude CLI to find auth tokens |
| `ANTHROPIC_API_KEY` | **Must be unset** | If set, Claude uses per-token billing instead of Max plan |

## Configuration (`config.toml`)

| Section | Purpose |
|---------|---------|
| `[general]` | Obsidian vault path, output directory, language, date format |
| `[report]` | Minimum source count |
| `[tracks.tech]` | Tech trend track: sources, scoring criteria |
| `[tracks.personal]` | Personal interest track: sources, domains, scoring criteria |
| `[user_profile]` | Skills, interests, goal |

## Development Workflow

### Making Changes to Research Behavior

1. **Scoring weights** -- Edit `config.toml` scoring_criteria
2. **Research sources** -- Edit `config.toml` track sources
3. **Report format** -- Edit `templates/report-template.md`
4. **Research depth/process** -- Edit `prompts/research-protocol.md`
5. **Theme selection** -- Edit `prompts/theme-selection-prompt.md`
6. **Execution instruction** -- Edit `prompts/task-prompt.md`

### Making Changes to Execution

1. Edit `scripts/daily-research.sh`
2. Run syntax check: `bash -n scripts/daily-research.sh`
3. Run shellcheck: `shellcheck scripts/daily-research.sh`
4. Run tests: `bats tests/`
5. Manual test (simulating launchd env):
   ```bash
   env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
     /bin/bash scripts/daily-research.sh
   ```

### Testing Prompts Interactively

```bash
cd ~/MyAI_Lab/daily-research
# Use a SEPARATE terminal (not inside Claude Code session)
claude
# Then manually follow research-protocol.md steps
```

**Important**: `claude -p` cannot be run from inside another Claude Code session (nested session check).

## Testing

```bash
# Run all tests
bats tests/

# Tests cover:
# - Script syntax validity (bash -n) for both daily-research.sh and eval-run.sh
# - Config file existence
# - launchd plist validity and schedule
# - Lock mechanism
# - Log directory permissions
# - past_topics.json validity
# - Security (no hardcoded keys, API key unset, log permissions)
# - Defensive programming (set -euo pipefail, trap, max-turns)
# - E2E mock: 2-pass flow, Sonnet fallback, JSON validation
# - No gtimeout/timeout dependency
# - Evaluation framework: judge prompt files, placeholders, bias mitigation
# - scores.example.jsonl schema validation
# - eval-run.sh integration hook in daily-research.sh
```

## Claude Code CLI Flags

### Pass 1: Theme Selection (Opus)

| Flag | Value | Purpose |
|------|-------|---------|
| `-p` | theme-selection-prompt.md content | Non-interactive mode |
| `--allowedTools` | `WebSearch,WebFetch,Read,Glob,Grep` | Read-only tools (no file writing) |
| `--max-turns` | `15` | Limit theme selection scope |
| `--model` | `opus` | Deep reasoning for theme quality |
| `--output-format` | `stream-json` | NDJSON stream, parsed by inline Python to extract result + tool counts |
| `--verbose` | - | Include detailed event stream |
| `--no-session-persistence` | - | Fresh context each run |

### Pass 2: Research & Writing (Sonnet)

| Flag | Value | Purpose |
|------|-------|---------|
| `-p` | task-prompt.md content (+ theme JSON if Pass 1 succeeded) | Non-interactive mode |
| `--append-system-prompt-file` | `prompts/research-protocol.md` | Inject research protocol while preserving defaults |
| `--allowedTools` | `WebSearch,WebFetch,Read,Write,Edit,Glob,Grep` | Full tool access for research and writing |
| `--max-turns` | `40` | Guideline limit for research depth |
| `--model` | `sonnet` | Speed + cost efficiency |
| `--output-format` | `json` | Structured output with metadata |
| `--no-session-persistence` | - | Fresh context each run |

## Architecture Notes

The 2-pass design was chosen based on blind LLM-as-Judge evaluation showing Opus produces +28% better theme selection while adding minimal cost (~$0.30 per run). See `docs/progress/agent-team-evaluation.md` for the full evaluation that led to this architecture.

Timeout is controlled via `--max-turns` rather than external process timeouts (gtimeout/timeout). External timeouts kill the claude process via signals, which can cause data loss. See `docs/progress/postmortem-2026-02-20.md` for details.

## Evaluation Framework (LLM-as-Judge)

After Pass 2 completes successfully, `daily-research.sh` invokes `scripts/eval-run.sh` as a non-fatal hook. Evaluation failures do not affect the main script's exit code.

### How It Works

1. `eval-run.sh` receives the date as its first argument (defaults to today)
2. Validates the DATE format (`YYYY-MM-DD`) to prevent path traversal
3. Reads `vault_path` and `output_dir` from `config.toml` via python3 (stdin-based)
4. Finds all reports matching `{DATE}_*.md` in the output directory
5. For each report, runs 6 independent Opus judge calls (one per dimension)
6. Extracts scores using a robust two-stage parser (direct JSON parse, then `raw_decode` fallback)
7. Appends a JSONL entry to `evals/scores.jsonl`

### 6 Evaluation Dimensions

| Dimension | Key in JSONL | What It Measures |
|-----------|-------------|-----------------|
| Factual Grounding | `factual_grounding` | Source quality, citation count, claim verification |
| Depth of Analysis | `depth_of_analysis` | Analytical depth beyond surface-level summary |
| Coherence | `coherence` | Logical flow, structure, readability |
| Specificity | `specificity` | Concrete tools, numbers, examples vs. abstract statements |
| Novelty | `novelty` | Fresh insights beyond common knowledge |
| Actionability | `actionability` | Practical, implementable development ideas |

Each dimension is scored 1-5 (30 points total per report).

### Judge Configuration

| Flag | Value | Purpose |
|------|-------|---------|
| `--append-system-prompt-file` | `evals/prompts/judge-system.md` | Bias mitigation + output format |
| `--max-turns` | `3` | Prevent tool-calling loops |
| `--model` | `claude-opus-4-6` | Deep reasoning for quality judgment |
| `--output-format` | `json` | Structured output for score extraction |

### Score Log Schema (`scores.jsonl`)

```json
{
  "date": "2026-02-21",
  "pipeline_version": "2pass-opus-sonnet",
  "track": "tech",
  "slug": "xcode-26-agentic-coding-mcp",
  "scores": {
    "factual_grounding": 4,
    "depth_of_analysis": 3,
    "coherence": 5,
    "specificity": 4,
    "novelty": 3,
    "actionability": 4
  },
  "total": 23,
  "judge_model": "claude-opus-4-6",
  "eval_duration_s": 42
}
```

### Pipeline Version

The `PIPELINE_VERSION` variable in `eval-run.sh` tracks the pipeline configuration. Update it manually when making functional changes to the pipeline (e.g., changing models, prompt structure, or execution flow). This enables meaningful before/after comparisons in score analysis.

**Statistical discipline**: Comparisons with n < 20 samples are "tentative signals" only. Version comparisons require n >= 20 to be considered valid.

### Input Validation

`eval-run.sh` includes the following safety checks:
- DATE format validation (`YYYY-MM-DD` regex) to prevent path traversal
- Topic and rationale length limits (200 and 500 chars respectively) in theme JSON validation
- Score range validation (1-5 integer)
- Graceful handling of malformed judge output via two-stage score extraction
