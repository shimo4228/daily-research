# Contributing / Development Guide

> Source of truth: `config.example.toml`, `scripts/*.sh`, `scripts/lib/dr_pipeline.py`, `prompts/*.md`, `com.example.daily-research.plist`

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
├── config.example.toml                  # Line → repo mapping, lines_per_day, context_files, daily flag (template)
├── past_topics.json                     # Question / topic history (deduplication, gitignored)
├── prompts/
│   ├── repo-research-protocol.md       # Per-repo research protocol, call 1 (--append-system-prompt-file)
│   └── verification-protocol.md        # Fresh-context verification + clarity protocol, call 2 (ADR-0017)
├── templates/
│   └── report-template.md              # Explanatory-report writing rules + fixed tail sections (frontmatter)
├── scripts/
│   ├── daily-research.sh               # Main entry point (rotation window: lines_per_day lines/day; call 1 research + call 2 verification/clarity); sources lib/
│   ├── check-auth.sh                   # OAuth check via real_auth_probe() + notification
│   ├── pre-commit.sh                   # Secret / syntax guard (git pre-commit hook)
│   └── lib/                             # Sourced shell libs + Python parser
│       ├── env.sh / log.sh / notify.sh / lock.sh / auth.sh / claude.sh
│       └── dr_pipeline.py              # Single stdlib-only JSON/TOML parsing module
├── state/                               # Per-line brief.md / pending.md / watched-sources.md /
│                                        #   playbook.md / runs/{date}.md (evidence file) / runs/{date}.json
│                                        #   (run receipt) / runs/{date}.verify.json (gitignored)
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
| `scripts/daily-research.sh` | Main entry point. Picks the `lines_per_day` lines of today's rotation window plus every `daily = true` line (`rotation-pick`, ADR-0010 / ADR-0011 / ADR-0017) and, per line, runs call 1 = `claude -p` with cwd = the line's `target_repo` (Opus, 25-min timeout, one retry on transient failure; 401 aborts), then call 2 = a fresh-context verification + clarity pass (Sonnet by default, 20-min timeout, fail-open). Sources `lib/`; includes env sanitization, auth probe, config schema check, receipt-driven report gate (ctl-015), report lint (ctl-016), and metrics append (incl. `clarity_pass` / `line_states` / `verification`). Called by launchd at AM 5:00. | `./scripts/daily-research.sh` |
| `scripts/check-auth.sh` | Checks Claude OAuth token validity via `real_auth_probe()` (shared `lib/auth.sh`; a real Haiku API probe, not `claude --version`, which succeeds even with an expired token). Shows macOS notification on failure. | `./scripts/check-auth.sh` |
| `scripts/pre-commit.sh` | Secret / syntax guard run as a git pre-commit hook. | (auto-run by git) |

## Environment Variables

| Variable | Source | Purpose |
|----------|--------|---------|
| `PATH` | plist + script | Must include `$HOME/.local/bin` (current Claude installer), `$HOME/.claude/local` (legacy), `/opt/homebrew/bin`, and `/usr/local/bin` |
| `HOME` | plist | Required for Claude CLI to find auth tokens |
| `ANTHROPIC_API_KEY` | **Must be unset** | If set, Claude uses per-token billing instead of Max plan |
| `CLAUDE_TIMEOUT` | Script (internal) | Timeout in seconds for `claude -p` calls via `run_claude()`. 0 = no timeout (default); the research run (call 1) sets 1500s (25 min), the verification + clarity run (call 2) sets 1200s (20 min) |
| `DEBUG` | User-set | Set to `1` to enable debug logging (PATH, CLAUDE_CMD) |
| `DR_DATE` | User-set (test seam) | `YYYY-MM-DD` — fixes the date used for rotation-pick and report names (e2e tests pin the rotation with it). Default: today |
| `DR_ONLY_TRACK` | User-set (test seam) | Run only this line among today's picked lines; errors if the line is not on today's rotation |
| `DR_FORCE_TRACK` | User-set (test seam) | Run this one line today even when today's rotation window does not include it (prompt-change trials). Not used on the launchd path |

## Configuration (`config.toml`)

| Section | Purpose |
|---------|---------|
| `[general]` | Obsidian vault path (`vault_path`), output directory (`output_dir`), `lines_per_day` (how many lines run per morning = the width of the rotation window; int >= 1, default 1, anything else fails fast), `self_signals` (self-contamination guard: the operator's own artifacts never count as external signals). `language` / `date_format` are informational — not read by any script |
| `[report]` | Minimum source count |
| `[verification]` | `model` — the model for call 2 (verification + clarity). Default `sonnet` |
| `[tracks.<name>]` | One block per line: `name`, `focus` (a description of the line's subject, not a selection criterion), `aliases`, `context_files` (repo-relative paths read after the question is chosen, Step 3b — task ledger, open questions, implementation log), `sources`, `template` (optional per-line section override, ADR-0015), `daily` (bool; `true` = run every morning outside the rotation, ADR-0011), plus one `[[tracks.<name>.repos]]` entry (`key`, `target_repo` — becomes the run's cwd; `target_doi` is informational, not read by scripts) |
| `[user_profile]` | Informational only — not read by any script |

## Development Workflow

### Making Changes to Research Behavior

1. **Line focus / lines per day** -- Edit `config.toml` `focus` (the subject) / `[general] lines_per_day` (question selection is Step 3 of the protocol, ADR-0017 — there are no scoring weights)
2. **Research sources** -- Edit `config.toml` line sources
3. **Repo context read after the question is chosen** -- Edit `config.toml` `context_files`
4. **Report format** -- Edit `templates/report-template.md` (keep ctl-016 lint sections in sync)
5. **Research process / objective function** -- Edit `prompts/repo-research-protocol.md`
6. **Verification and clarity rules** -- Edit `prompts/verification-protocol.md`; the model comes from `[verification] model`

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
claude
# Then manually follow prompts/repo-research-protocol.md steps
```

**Note**: `./scripts/daily-research.sh` can also be run from inside a Claude Code session — `lib/env.sh` unsets `CLAUDECODE`, so the nested-session check passes (verified 2026-08-22). Use the `DR_FORCE_TRACK` / `DR_ONLY_TRACK` / `DR_DATE` seams above to run a single line.

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
# - E2E mock: per-line flow (cwd = repo, prompt injection), retry, receipt-driven report gate
#   (article / brief / quiet / hold / missing receipt / mismatch), call 2 verification tally
# - lib/*.sh units: env sanitize, atomic lock, real auth probe, exit classify
```

## Claude Code CLI Flags

### Call 1 — research run (Opus, per picked line: the rotation window's `lines_per_day` lines + every daily line)

The run is invoked with `cd "$TARGET_REPO"` so the repo's own CLAUDE.md auto-loads as context.

| Flag | Value | Purpose |
|------|-------|---------|
| `-p` | Per-line prompt (line brief from `dr_pipeline.py line-brief` + allowed write paths — the vault report, `state/<line>/` brief / pending / watched-sources / playbook / evidence file / run receipt, and `past_topics.json` — + past-question dedup data + report template) | Non-interactive mode |
| `--permission-mode` | `default` | Use default permission handling |
| `--append-system-prompt-file` | `prompts/repo-research-protocol.md` | Inject the research protocol while preserving defaults |
| `--allowedTools` | `WebSearch,WebFetch,Read,Glob,Grep` + `Write`/`Edit` scoped to absolute paths (vault report dir, `state/<line>/`, `past_topics.json`) | Repo stays read-only at the permission layer; writes go only to the three declared targets |
| `--max-turns` | `55` | Guideline limit for research depth |
| `--model` | `opus` | Rotation frees the daily budget for a single high-quality report (ADR-0010) |
| `--output-format` | `json` | Structured output with metadata (fed to metrics) |
| `--no-session-persistence` | - | Fresh context each run |

### Call 2 — verification + clarity (Sonnet by default, per line that ended as article or brief)

| Flag | Value | Purpose |
|------|-------|---------|
| `-p` | Paths of the note, the evidence file, and `runs/{date}.verify.json` (the only two writable files) | Non-interactive mode |
| `--append-system-prompt-file` | `prompts/verification-protocol.md` | Inject clarity (Step A) then source verification (Step B) |
| `--allowedTools` | `Read,WebFetch` + `Edit` of the day's note and `runs/{date}.verify.json` | Only the note and the verification result can be written |
| `--disallowedTools` | `Bash,Task,NotebookEdit` + `WebSearch` | Verification re-fetches the sources in the evidence file and the ソース section; it starts no new search |
| `--max-turns` | `30` | Enough depth to WebFetch every claim |
| `--model` | `[verification] model` (default `sonnet`) | Raise to opus if misses become visible |

The day's `verify.json` is removed before call 2 starts and read back run-scoped (newer than `$LOCK_DIR/pid`).

**Note**: All `claude -p` calls use `< /dev/null` stdin redirect via the `run_claude()` wrapper. This prevents MCP stdio communication from conflicting with terminal stdin, which was a root cause of past MCP hangs.

## Architecture Notes

The per-repo single-pass design replaced the earlier central 2-pass (Opus theme selection → Sonnet research) pipeline on 2026-08-04: theme selection through synced concept graphs converged on corroboration surveys, while the operational context that knows what to advance lives inside each repo (ADR-0008).

The research run is bounded two ways: `--max-turns 55` and a 25-minute external timeout (`CLAUDE_TIMEOUT=1500` via `run_claude()`, requires coreutils `timeout`). A transient failure is retried once; a 401 aborts immediately since the same auth would fail everywhere.

The report-existence gate (ctl-015) reads the run receipt `state/<line>/runs/{date}.json`: a missing or invalid receipt fails the line, `article` / `brief` require a run-scoped report, and `quiet` / `hold` pass without a file. Run scope is decided with `find -newer "$LOCK_DIR/pid"` because bash 3.2's `-nt` only has second resolution. A receipt claiming quiet/hold while a report exists loses to the file (file wins) and is counted as `mismatch`; a quiet/hold with `reason_code = fetch_failed` or zero web searches is counted as `suspect`.

Call 2 (verification + clarity, ADR-0017) runs after the gate: a fresh-context process (`--max-turns 30`, `CLAUDE_TIMEOUT=1200`, `--allowedTools` = Read + WebFetch + Edit of the day's note and `runs/{date}.verify.json`, with WebSearch added to `--disallowedTools`) reads the finished note as a first-contact reader, fixes comprehension stumbles, and then checks every claim in the evidence file against its source. Its failure is fail-open: the log records `WARN: clarity pass failed`, the unverified (or, on timeout, partially revised) note survives, and `FINAL_EXIT` is unaffected — but the line is reported as `unverified` in the metrics and the notification.

`metrics.jsonl` keeps the pre-ADR-0008 record shape for compatibility with `expect-check` / `/dr-review`: the research run JSON is aggregated into the `pass2` field, `pass1` is always `None`, `fallback_used` means "a retry occurred" (`pass2` sums every attempt), `source` is `live` or `test` (runs under `DR_FORCE_TRACK` / `DR_ONLY_TRACK` are recorded as `test` and excluded from `expect-check` / `/dr-review` aggregation), and `clarity_pass` records call 2's `{ran, ok, cost, turns, ...}` (the label is kept for compatibility; what it measures is the verification + clarity pass). Each record also carries `line_states {article, brief, quiet, hold, mismatch, suspect, unverified}` (always emitted, zeros included) and `verification {supported, partial, unsupported, unverifiable, edits, lines_verified}` (`None` on a day with no VERIFY line). Verdicts themselves are never stored — the eval is in-loop (ADR-0010) and only the verification tally survives.

## Persistent Memory Layer

A Mem0 Cloud MCP integration was merged on 2026-02-26 but remained in zero-operation state for 32 days due to a missing `.mcp.json` and a non-functional health check. It was removed on 2026-05-23. Its successor, the local JSON-LD concept cluster graph (`graph.jsonld`), was itself frozen on 2026-08-04 (ADR-0008) — it receives no more increments and is kept as a readable archive. Persistent working state now lives in `state/<line>/` (brief, pending, watched-sources, playbook, and the runs/ evidence file, receipt, and verification result) and `past_topics.json`, both local files that fail loudly.
