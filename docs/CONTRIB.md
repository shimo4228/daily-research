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
├── config.example.toml                  # Line → repo mapping, context_files, scoring (template)
├── past_topics.json                     # Topic history (deduplication, gitignored)
├── prompts/
│   └── repo-research-protocol.md       # Per-repo research protocol (--append-system-prompt-file)
├── templates/
│   └── report-template.md              # Explanatory-report writing rules + fixed tail sections (frontmatter)
├── scripts/
│   ├── daily-research.sh               # Main entry point (rotation: one line/day; call 1 research + call 2 clarity); sources lib/
│   ├── check-auth.sh                   # OAuth check via real_auth_probe() + notification
│   ├── pre-commit.sh                   # Secret / syntax guard (git pre-commit hook)
│   └── lib/                             # Sourced shell libs + Python parser
│       ├── env.sh / log.sh / notify.sh / lock.sh / auth.sh / claude.sh
│       └── dr_pipeline.py              # Single stdlib-only JSON/TOML parsing module
├── state/                               # Per-line watched-sources / playbook / last-seen (gitignored)
├── graph.jsonld                         # FROZEN archive (retired concept-graph pipeline)
├── com.example.daily-research.plist    # launchd schedule (AM 5:00, research)
├── tests/
│   ├── test-daily-research.bats        # Unit tests (syntax, config, security)
│   ├── test-e2e-mock.bats             # E2E mock tests (per-line flow)
│   ├── test-lib.bats                  # lib/*.sh unit tests (env, lock, auth, claude)
│   └── dr_pipeline_test.py            # pytest for dr_pipeline.py (dev-only, .venv)
├── logs/                                # Execution logs (date-stamped, auto-rotated 30d)
├── docs/
│   ├── RUNBOOK.md / RUNBOOK.ja.md      # Operations guide
│   ├── CONTRIB.md / CONTRIB.ja.md      # Development guide (this file)
│   ├── graph-schema.md                 # Frozen graph.jsonld archive schema (historical)
│   └── adr/                             # Architecture Decision Records
└── .claude/settings.local.json          # Claude Code project permissions
```

## Scripts Reference

| Script | Description | Usage |
|--------|-------------|-------|
| `scripts/daily-research.sh` | Main entry point. Picks one rotated line per day plus every `daily = true` line (`rotation-pick`, ADR-0010 / ADR-0011) and, per line, runs call 1 = `claude -p` with cwd = the line's `target_repo` (Opus, 25-min timeout, one retry on transient failure; 401 aborts), then call 2 = a fresh-context clarity revision (Sonnet, 15-min timeout, fail-open). Sources `lib/`; includes env sanitization, auth probe, config schema check, report gate (ctl-015), report lint (ctl-016), and metrics append (incl. `clarity_pass`). Called by launchd at AM 5:00. | `./scripts/daily-research.sh` |
| `scripts/check-auth.sh` | Checks Claude OAuth token validity via `real_auth_probe()` (shared `lib/auth.sh`; a real Haiku API probe, not `claude --version`, which succeeds even with an expired token). Shows macOS notification on failure. | `./scripts/check-auth.sh` |
| `scripts/pre-commit.sh` | Secret / syntax guard run as a git pre-commit hook. | (auto-run by git) |

## Environment Variables

| Variable | Source | Purpose |
|----------|--------|---------|
| `PATH` | plist + script | Must include `$HOME/.local/bin` (current Claude installer), `$HOME/.claude/local` (legacy), `/opt/homebrew/bin`, and `/usr/local/bin` |
| `HOME` | plist | Required for Claude CLI to find auth tokens |
| `ANTHROPIC_API_KEY` | **Must be unset** | If set, Claude uses per-token billing instead of Max plan |
| `CLAUDE_TIMEOUT` | Script (internal) | Timeout in seconds for `claude -p` calls via `run_claude()`. 0 = no timeout (default); the research run (call 1) sets 1500s (25 min), the clarity run (call 2) sets 900s (15 min) |
| `DEBUG` | User-set | Set to `1` to enable debug logging (PATH, CLAUDE_CMD) |

## Configuration (`config.toml`)

| Section | Purpose |
|---------|---------|
| `[general]` | Obsidian vault path, output directory, language, date format, `self_signals` (self-contamination guard: the operator's own artifacts never count as external signals) |
| `[report]` | Minimum source count |
| `[tracks.<name>]` | One block per line: `focus`, `aliases`, `context_files` (repo-relative paths read at the start of each run — task ledger, open questions, implementation log), `sources`, `scoring_criteria`, plus one `[[tracks.<name>.repos]]` entry (`key`, `target_repo` — becomes the run's cwd, `target_doi` optional) |
| `[user_profile]` | Optional skills / interests / goal hints |

## Development Workflow

### Making Changes to Research Behavior

1. **Scoring weights** -- Edit `config.toml` scoring_criteria
2. **Research sources** -- Edit `config.toml` line sources
3. **Repo context read by each run** -- Edit `config.toml` `context_files`
4. **Report format** -- Edit `templates/report-template.md` (keep ctl-016 lint sections in sync)
5. **Research process / objective function** -- Edit `prompts/repo-research-protocol.md`

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
# Then manually follow prompts/repo-research-protocol.md steps
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
# - E2E mock: per-line flow (cwd = repo, prompt injection), retry, per-line report gate
# - lib/*.sh units: env sanitize, atomic lock, real auth probe, exit classify
```

## Claude Code CLI Flags

### Call 1 — research run (Opus, per picked line: one rotated + every daily line)

The run is invoked with `cd "$TARGET_REPO"` so the repo's own CLAUDE.md auto-loads as context.

| Flag | Value | Purpose |
|------|-------|---------|
| `-p` | Per-line prompt (line brief from `dr_pipeline.py line-brief` + allowed write paths + past-themes dedup data + report template) | Non-interactive mode |
| `--permission-mode` | `default` | Use default permission handling |
| `--append-system-prompt-file` | `prompts/repo-research-protocol.md` | Inject the research protocol while preserving defaults |
| `--allowedTools` | `WebSearch,WebFetch,Read,Glob,Grep` + `Write`/`Edit` scoped to absolute paths (vault report dir, `state/<line>/`, `past_topics.json`) | Repo stays read-only at the permission layer; writes go only to the three declared targets |
| `--max-turns` | `55` | Guideline limit for research depth |
| `--model` | `opus` | Rotation frees the daily budget for a single high-quality report (ADR-0010) |
| `--output-format` | `json` | Structured output with metadata (fed to metrics) |
| `--no-session-persistence` | - | Fresh context each run |

**Note**: All `claude -p` calls use `< /dev/null` stdin redirect via the `run_claude()` wrapper. This prevents MCP stdio communication from conflicting with terminal stdin, which was a root cause of past MCP hangs.

## Architecture Notes

The per-repo single-pass design replaced the earlier central 2-pass (Opus theme selection → Sonnet research) pipeline on 2026-08-04: theme selection through synced concept graphs converged on corroboration surveys, while the operational context that knows what to advance lives inside each repo (ADR-0008).

The research run is bounded two ways: `--max-turns 55` and a 25-minute external timeout (`CLAUDE_TIMEOUT=1500` via `run_claude()`, requires coreutils `timeout`). A transient failure is retried once; a 401 aborts immediately since the same auth would fail everywhere.

Call 2 (clarity revision, ADR-0010) runs after the report-existence gate: a fresh-context Sonnet process (`--max-turns 15`, `CLAUDE_TIMEOUT=900`, `--allowedTools` = Read + Edit of the day's note only) reads the finished note as a first-contact reader and fixes comprehension stumbles. Its failure is fail-open: the log records `WARN: clarity pass failed`, the unrevised (or, on timeout, partially revised) note survives, and `FINAL_EXIT` is unaffected.

`metrics.jsonl` keeps the pre-ADR-0008 record shape for compatibility with `expect-check` / `/dr-review`: the research run JSON is aggregated into the `pass2` field, `pass1` is always `None`, `fallback_used` means "a retry occurred", and `clarity_pass` records call 2's `{ran, ok, cost, turns, ...}` (verdicts themselves are never stored — the eval is in-loop, ADR-0010).

## Persistent Memory Layer

A Mem0 Cloud MCP integration was merged on 2026-02-26 but remained in zero-operation state for 32 days due to a missing `.mcp.json` and a non-functional health check. It was removed on 2026-05-23. Its successor, the local JSON-LD concept cluster graph (`graph.jsonld`), was itself frozen on 2026-08-04 (ADR-0008) — it receives no more increments and is kept as a readable archive. Persistent working state now lives in `state/<line>/` (watched-sources, playbook) and `past_topics.json`, both local files that fail loudly.
