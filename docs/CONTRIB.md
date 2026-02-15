# Contributing / Development Guide

> Source of truth: `config.example.toml`, `scripts/*.sh`, `com.example.daily-research.plist`

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| Claude Code CLI | Core execution engine | `brew install claude` or [docs.anthropic.com](https://docs.anthropic.com) |
| Claude Max plan | Zero-cost API usage | Subscription required |
| macOS (launchd) | Scheduler | Built-in |
| bats-core | Shell test framework | `brew install bats-core` |
| shellcheck | Shell linting | `brew install shellcheck` |

## Project Structure

```
daily-research/
├── config.example.toml                  # Research tracks, scoring, output settings (template)
├── past_topics.json                     # Topic history (deduplication, gitignored)
├── prompts/
│   ├── task-prompt.md                   # Execution instruction (claude -p argument)
│   └── research-protocol.md            # Research protocol (--append-system-prompt-file)
├── templates/
│   └── report-template.md              # Obsidian report format with frontmatter
├── scripts/
│   ├── daily-research.sh               # Main wrapper (launchd entry point)
│   └── check-auth.sh                   # OAuth authentication check + notification
├── com.example.daily-research.plist   # launchd schedule (AM 5:00)
├── tests/
│   └── test-daily-research.bats        # Shell tests (syntax, config, security)
├── logs/                                # Execution logs (date-stamped, auto-rotated 30d)
├── docs/
│   ├── plans/plan-a-implementation.md   # Authoritative design document
│   └── archive/                         # Superseded design docs
└── .claude/settings.local.json          # Claude Code project permissions
```

## Scripts Reference

| Script | Description | Usage |
|--------|-------------|-------|
| `scripts/daily-research.sh` | Main entry point. Sanitizes env, checks auth, runs `claude -p` with research protocol, logs results. Called by launchd at AM 5:00. | `./scripts/daily-research.sh` |
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
5. **Execution instruction** -- Edit `prompts/task-prompt.md`

### Making Changes to Execution

1. Edit `scripts/daily-research.sh`
2. Run syntax check: `bash -n scripts/daily-research.sh`
3. Run shellcheck: `shellcheck scripts/daily-research.sh`
4. Run tests: `bats tests/test-daily-research.bats`
5. Manual test (simulating launchd env):
   ```bash
   env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
     /bin/bash scripts/daily-research.sh
   ```

### Testing Prompts Interactively

```bash
cd ~/MyAI_Lab/daily-research
CLAUDECODE= claude  # Bypass nested session check
# Then manually follow research-protocol.md steps
```

## Testing

```bash
# Run all tests
bats tests/test-daily-research.bats

# Tests cover:
# - Script syntax validity (bash -n)
# - Config file existence
# - launchd plist validity and schedule
# - Lock mechanism
# - Log directory permissions
# - past_topics.json validity
# - Security (no hardcoded keys, API key unset, log permissions)
# - Defensive programming (set -euo pipefail, trap, timeout)
```

## Claude Code CLI Flags

Used in `daily-research.sh`:

| Flag | Value | Purpose |
|------|-------|---------|
| `-p` | task-prompt.md content | Non-interactive mode |
| `--append-system-prompt-file` | `prompts/research-protocol.md` | Inject research protocol while preserving defaults |
| `--allowedTools` | `WebSearch,WebFetch,Read,Write,Glob,Grep` | Auto-approve these tools |
| `--max-turns` | `40` | Guideline limit (not strict) |
| `--model` | `sonnet` | Model selection |
| `--output-format` | `json` | Structured output |
| `--no-session-persistence` | - | Fresh context each run |
