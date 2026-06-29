# Contributing / Development Guide

> Source of truth: `config.example.toml`, `scripts/*.sh`, `com.example.daily-research.plist`

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| Claude Code CLI | Core execution engine | `brew install claude` or [docs.anthropic.com](https://docs.anthropic.com) |
| Claude Max plan | Zero-cost API usage | Subscription required |
| macOS (launchd) | Scheduler | Built-in |
| python3 >= 3.11 | JSON/TOML parsing (`scripts/lib/dr_pipeline.py`); stdlib only | Homebrew `python3` (macOS system 3.9 lacks `tomllib`) |
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
│   ├── daily-research.sh               # Main entry point (2-pass: Opus → Sonnet); sources lib/
│   ├── coverage-report.sh              # Uncovered-concept report, injected into Pass 1
│   ├── bootstrap-graph.sh              # One-shot graph.jsonld bootstrap (Opus clustering)
│   ├── check-auth.sh                   # OAuth check via real_auth_probe() + notification
│   ├── pre-commit.sh                   # Secret / syntax guard (git pre-commit hook)
│   └── lib/                             # Sourced shell libs + Python parser
│       ├── env.sh / log.sh / notify.sh / lock.sh / graph.sh / auth.sh / claude.sh
│       └── dr_pipeline.py              # Single stdlib-only JSON/TOML parsing module
├── com.example.daily-research.plist   # launchd schedule (AM 5:00)
├── tests/
│   ├── test-daily-research.bats        # Unit tests (syntax, config, security)
│   ├── test-e2e-mock.bats             # E2E mock tests
│   ├── test-lib.bats                  # lib/*.sh unit tests (env, lock, graph, auth, claude)
│   └── dr_pipeline_test.py            # pytest for dr_pipeline.py (dev-only, .venv)
├── logs/                                # Execution logs (date-stamped, auto-rotated 30d)
├── docs/
│   ├── RUNBOOK.md / RUNBOOK.ja.md      # Operations guide
│   ├── CONTRIB.md / CONTRIB.ja.md      # Development guide (this file)
│   ├── graph-schema.md                 # graph.jsonld schema spec
│   └── adr/                             # Architecture Decision Records
└── .claude/settings.local.json          # Claude Code project permissions
```

## Scripts Reference

| Script | Description | Usage |
|--------|-------------|-------|
| `scripts/daily-research.sh` | Main entry point. 2-pass execution: Pass 1 (Opus theme selection) → Pass 2 (Sonnet research & writing). Sources `lib/`; includes env sanitization, auth probe, repo-graph sync, coverage report, JSON validation, and Sonnet fallback. Called by launchd at AM 5:00. | `./scripts/daily-research.sh` |
| `scripts/coverage-report.sh` | Computes uncovered concepts per track (repo graph minus reinforced concepts); injected into Pass 1. | `./scripts/coverage-report.sh` |
| `scripts/bootstrap-graph.sh` | One-shot `graph.jsonld` bootstrap from existing topic history (Opus clustering). | `./scripts/bootstrap-graph.sh` |
| `scripts/check-auth.sh` | Checks Claude OAuth token validity via `real_auth_probe()` (shared `lib/auth.sh`; a real Haiku API probe, not `claude --version`, which succeeds even with an expired token). Shows macOS notification on failure. | `./scripts/check-auth.sh` |
| `scripts/pre-commit.sh` | Secret / syntax guard run as a git pre-commit hook. | (auto-run by git) |

## Environment Variables

| Variable | Source | Purpose |
|----------|--------|---------|
| `PATH` | plist + script | Must include `/opt/homebrew/bin`, `/usr/local/bin`, `$HOME/.claude/local` |
| `HOME` | plist | Required for Claude CLI to find auth tokens |
| `ANTHROPIC_API_KEY` | **Must be unset** | If set, Claude uses per-token billing instead of Max plan |
| `CLAUDE_TIMEOUT` | Script (internal) | Timeout in seconds for `claude -p` calls via `run_claude()`. 0 = no timeout (default); Pass 2 sets 1800s |
| `DEBUG` | User-set | Set to `1` to enable debug logging (PATH, CLAUDE_CMD) |

## Configuration (`config.toml`)

| Section | Purpose |
|---------|---------|
| `[general]` | Obsidian vault path, output directory, language, date format |
| `[report]` | Minimum source count |
| `[tracks.<name>]` | One block per track: `target_repo`, `target_graph`, `sources`, `scoring_criteria` (config.example.toml ships `repo_a` / `repo_b` / `repo_c` templates) |
| `[user_profile]` | Optional skills / interests / goal hints |

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
# - Script syntax validity (bash -n) for daily-research.sh and lib/*.sh
# - Config file existence
# - launchd plist validity and schedule
# - Lock mechanism
# - Log directory permissions
# - past_topics.json validity
# - Security (no hardcoded keys, API key unset, log permissions)
# - Defensive programming (set -euo pipefail, trap, max-turns)
# - E2E mock: 2-pass flow, Sonnet fallback, JSON validation
# - No gtimeout/timeout dependency
# - lib/*.sh units: env sanitize, atomic lock, graph health, real auth probe, exit classify
```

## Claude Code CLI Flags

### Pass 1: Theme Selection (Opus)

| Flag | Value | Purpose |
|------|-------|---------|
| `-p` | theme-selection-prompt.md content | Non-interactive mode |
| `--permission-mode` | `default` | Use default permission handling |
| `--allowedTools` | `WebSearch,WebFetch,Read,Glob,Grep` | Read-only tools (no file writing) |
| `--max-turns` | `15` | Limit theme selection scope |
| `--model` | `opus` | Deep reasoning for theme quality |
| `--output-format` | `stream-json` | NDJSON stream, parsed by `lib/dr_pipeline.py` to extract result + tool counts |
| `--verbose` | - | Include detailed event stream |
| `--no-session-persistence` | - | Fresh context each run |

### Pass 2: Research & Writing (Sonnet)

| Flag | Value | Purpose |
|------|-------|---------|
| `-p` | task-prompt.md content (+ theme JSON if Pass 1 succeeded) | Non-interactive mode |
| `--permission-mode` | `default` | Use default permission handling |
| `--append-system-prompt-file` | `prompts/research-protocol.md` | Inject research protocol while preserving defaults |
| `--allowedTools` | `WebSearch,WebFetch,Read,Write,Edit,Glob,Grep` | Full tool access for research and writing |
| `--max-turns` | `55` | Guideline limit for research depth |
| `--model` | `sonnet` | Speed + cost efficiency |
| `--output-format` | `json` | Structured output with metadata |
| `--no-session-persistence` | - | Fresh context each run |

**Note**: All `claude -p` calls use `< /dev/null` stdin redirect via the `run_claude()` wrapper. This prevents MCP stdio communication from conflicting with terminal stdin, which was a root cause of past MCP hangs.

## Architecture Notes

The 2-pass design was chosen based on a one-time blind evaluation showing Opus produces +28% better theme selection while adding minimal cost (~$0.30 per run).

Timeout is controlled via `--max-turns` rather than external process timeouts (gtimeout/timeout). External timeouts kill the claude process via signals, which can cause data loss.

## Persistent Memory Layer

A Mem0 Cloud MCP integration was merged on 2026-02-26 but remained in zero-operation state for 32 days due to a missing `.mcp.json` and a non-functional health check. It was removed on 2026-05-23. The successor is a local JSON-LD concept cluster graph (`graph.jsonld`) that eliminates external MCP dependency and the structural risk of silent failures.
