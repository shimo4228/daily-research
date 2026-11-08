# Contributing / Development Guide

> Source of truth: `config.example.toml`, `scripts/*.sh`, `scripts/lib/dr_pipeline.py`, `prompts/*.md`, `com.example.daily-research.plist`

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| Claude Code CLI | Core execution engine | `brew install claude` or [docs.anthropic.com](https://docs.anthropic.com) |
| Claude Max plan or a Claude API key | Pays for the `claude -p` calls; `[billing] mode` in `config.toml` picks which | Subscription, or a key from platform.claude.com kept in an env file outside the repo |
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
│   ├── repo-research-protocol.md       # Per-repo research protocol, call 1, mode = "repo" (--append-system-prompt-file)
│   ├── ecosystem-research-protocol.md  # Ecosystem research protocol, call 1, mode = "ecosystem" (ADR-0018)
│   └── verification-protocol.md        # Fresh-context verification + clarity protocol, call 2 (ADR-0017)
├── templates/
│   ├── report-template.md              # Explanatory-report writing rules + fixed tail sections (frontmatter)
│   ├── report-template-edge.md         # Per-line section override for edge (ADR-0015)
│   └── report-template-ecosystem.md    # Per-line section override for ecosystem lines (ADR-0018)
├── scripts/
│   ├── daily-research.sh               # Main entry point (rotation window: lines_per_day lines/day; call 1 research + call 2 verification/clarity); sources lib/
│   ├── check-auth.sh                   # Auth check on the [billing] path via real_auth_probe() + notification
│   ├── pre-commit.sh                   # Secret / syntax guard (git pre-commit hook)
│   ├── dev/                             # Dev-only isolated trial runs: sandbox-run.sh / eval_run.py / compare.py
│   └── lib/                             # Sourced shell libs + Python parser
│       ├── env.sh / log.sh / notify.sh / lock.sh / auth.sh / claude.sh / billing.sh
│       └── dr_pipeline.py              # Single stdlib-only JSON/TOML parsing module
├── state/                               # Per-line brief.md (static, written by you) / pending.md /
│                                        #   watched-sources.md + watched-archive.md (ecosystem lines) / runs/{date}.md (evidence file) /
│                                        #   runs/{date}.json (run receipt) / runs/{date}.verify.json / pre-verify/{date}.md
│                                        #   (call 2's before-copy, written by the script, not the model) (gitignored)
├── graph.jsonld                         # FROZEN archive (retired concept-graph pipeline)
├── com.example.daily-research.plist    # launchd schedule (AM 5:00, research)
├── tests/
│   ├── test-billing.bats               # API billing: error classes, key handoff, per-call / daily / monthly caps
│   ├── test-daily-research.bats        # Unit tests (syntax, config, security, the call-1 protocols' shared contract)
│   ├── test-docs.bats                  # Docs name keys and files instead of copying values (lines_per_day, amounts, line names)
│   ├── test-e2e-mock.bats             # E2E mock tests (per-line flow)
│   ├── test-lib.bats                  # lib/*.sh unit tests (env, lock, auth, claude)
│   ├── test-sandbox-run.bats          # scripts/dev/sandbox-run.sh end to end with a mock claude
│   ├── dev_tools_test.py              # pytest for scripts/dev/ (config rewrite, collect, eval metrics)
│   ├── dr_pipeline_test.py            # pytest for dr_pipeline.py (dev-only, .venv)
│   ├── dr_pipeline_strength_test.py   # pytest pinning the dr_pipeline.py behaviors mutation testing found unguarded
│   ├── test_helper.bash               # shared bats helpers (refute_grep — write negative grep assertions with it, never `! grep`)
│   └── fixtures/                      # configs and result JSONs for the tests; verify-golden/ = manual call-2 check (its README)
├── logs/                                # Execution logs (date-stamped, auto-rotated 30d)
├── docs/
│   ├── RUNBOOK.md / RUNBOOK.ja.md      # Operations guide
│   ├── CONTRIB.md / CONTRIB.ja.md      # Development guide (this file)
│   ├── graph-schema.md                 # Frozen graph.jsonld archive schema (historical)
│   ├── decision-history/                # Dated, past-tense decision records (index: README.md)
│   ├── plans/                           # Improvement plans with baselines and verdicts (reports in research/)
│   └── design/                          # Dated design notes
└── .claude/
    ├── verify.sh / verify.md            # Test + lint gate (tool selection recorded in verify.md)
    ├── skills/dr-review/                # Interactive self-improvement review (/dr-review)
    └── settings.json / settings.local.json  # Local Claude Code settings (gitignored)
```

## Scripts Reference

| Script | Description | Usage |
|--------|-------------|-------|
| `scripts/daily-research.sh` | Main entry point. Picks the `lines_per_day` lines of today's rotation window plus every `daily = true` line (`rotation-pick`, ADR-0010 / ADR-0011 / ADR-0017) and, per line, runs call 1 = `claude -p` with cwd = the line's `target_repo` (Opus, 25-min timeout, one retry on a failure other than auth / billing / the per-call cap; 401 aborts) — or, when `[tracks.<name>].mode = "ecosystem"`, with cwd = `state/<line>` and the ecosystem protocol (ADR-0018; the branch is decided from `mode`, never from the line's name) — then call 2 = a fresh-context verification + clarity pass (Sonnet by default, 20-min timeout, fail-open). Both calls and the auth probe run with `--safe-mode` (ADR-0019). Sources `lib/`; includes env sanitization, billing setup (`[billing]`), auth probe, config schema check, receipt-driven report gate (ctl-015), the question-history append (`past-topics-append`), call 2's before-copy and `verify-diff`, report lint (ctl-016), and metrics append (incl. `clarity_pass` / `line_states` / `verification`). Called by launchd at AM 5:00. | `./scripts/daily-research.sh` |
| `scripts/check-auth.sh` | Checks Claude auth on the path `[billing] mode` selects (OAuth, or the API key from `env_file`; api mode also prints the month's spend) via `real_auth_probe()` (shared `lib/auth.sh`; a real Haiku API probe, not `claude --version`, which succeeds even with an expired token). Shows macOS notification on failure. | `./scripts/check-auth.sh` |
| `scripts/pre-commit.sh` | Secret / syntax guard run as a git pre-commit hook. | (auto-run by git) |

## Environment Variables

| Variable | Source | Purpose |
|----------|--------|---------|
| `PATH` | plist + script | Must include `$HOME/.local/bin` (current Claude installer), `$HOME/.claude/local` (legacy), `/opt/homebrew/bin`, and `/usr/local/bin` |
| `HOME` | plist | Required for Claude CLI to find auth tokens |
| `ANTHROPIC_API_KEY` | `[billing].env_file` only | `lib/env.sh` drops any inherited value; in `api` mode `lib/billing.sh` reads it from `env_file` and exports it, in `subscription` mode it stays unset (OAuth) |
| `CLAUDE_TIMEOUT` | Script (internal) | Timeout in seconds for `claude -p` calls via `run_claude()`. 0 = no timeout (default); the research run (call 1) sets 1500s (25 min), the verification + clarity run (call 2) sets 1200s (20 min) |
| `DEBUG` | User-set | Set to `1` to enable debug logging (PATH, CLAUDE_CMD) |
| `DR_DATE` | User-set (test seam) | `YYYY-MM-DD` — fixes the date used for rotation-pick and report names (e2e tests pin the rotation with it). Default: today |
| `DR_ONLY_TRACK` | User-set (test seam) | Run only this line among today's picked lines; errors if the line is not on today's rotation |
| `DR_FORCE_TRACK` | User-set (test seam) | Run this one line today even when today's rotation window does not include it (prompt-change trials). Not used on the launchd path |

## Configuration (`config.toml`)

| Section | Purpose |
|---------|---------|
| `[general]` | Obsidian vault path (`vault_path`), output directory (`output_dir`), `lines_per_day` (how many lines run per morning = the width of the rotation window; int >= 1, default 1, anything else fails fast), `self_signals` (self-contamination guard: the operator's own artifacts never count as external signals). `language` / `date_format` are informational — not read by any script |
| `[report]` | `min_sources` — below this many source URLs, report lint (ctl-016) records a soft finding |
| `[verification]` | `model` — the model for call 2 (verification + clarity). Default `sonnet` |
| `[tracks.<name>]` | One block per line: `name`, `focus` (a description of the line's subject, not a selection criterion), `aliases`, `context_files` (repo-relative paths read after the question is chosen, Step 3b — task ledger, open questions, implementation log), `sources`, `template` (optional per-line section override, ADR-0015), `daily` (bool; `true` = run every morning outside the rotation, ADR-0011), `mode` (`"repo"` by default and may be omitted, or `"ecosystem"`; an unknown value fails the schema check, ADR-0018), plus one `[[tracks.<name>.repos]]` entry for a repo line (`key`, `target_repo` — becomes the run's cwd; `target_doi` is informational, not read by scripts). `repos` must be an array of tables whose every entry sets `key` and `target_repo` to non-empty strings — a single `[tracks.<name>.repos]` table or an entry missing either key fails the schema check at startup. A `mode = "ecosystem"` line must set neither `repos` nor `context_files` — the schema rejects both, since such a line has no repo context |
| `[user_profile]` | Informational only — not read by any script |

## Development Workflow

### Making Changes to Research Behavior

1. **Line focus / lines per day** -- Edit `config.toml` `focus` (the subject) / `[general] lines_per_day` (question selection is Step 3 of the protocol, ADR-0017 — there are no scoring weights)
2. **Research sources** -- Edit `config.toml` line sources
3. **Repo context read after the question is chosen** -- Edit `config.toml` `context_files`
4. **Report format** -- Edit `templates/report-template.md` (keep ctl-016 lint sections in sync; per-line overrides such as `templates/report-template-edge.md` and `templates/report-template-ecosystem.md` need the same two fixed tail sections)
5. **Research process / objective function** -- Edit `prompts/repo-research-protocol.md`, or `prompts/ecosystem-research-protocol.md` for ecosystem lines. The two call-1 protocols share one contract — receipt format, evidence-file table, the four content states, the fixed tail sections — so a change to either side is made on both; `tests/test-daily-research.bats` applies the same assertions to each file, and pytest checks each protocol's receipt example against `RECEIPT_KEYS`
6. **Verification and clarity rules** -- Edit `prompts/verification-protocol.md`; the model comes from `[verification] model`

### Making Changes to Execution

1. Edit `scripts/daily-research.sh`
2. Run syntax check: `bash -n scripts/daily-research.sh`
3. Run shellcheck: `shellcheck scripts/daily-research.sh`
4. Run the gate: `.claude/verify.sh` (ruff, bash -n, shellcheck, `bats tests/`, pytest)
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

**Isolated trial runs**: `scripts/dev/sandbox-run.sh --line <line> --out <dir> (--ref <git-ref> | --tree <dir>)` runs the same `daily-research.sh` for one line in a throwaway `PROJECT_DIR` and vault, on the subscription path, under a launchd-like clean environment, and collects the note, receipt, evidence file, `verify.json`, log, metrics record and both result JSONs into `<dir>`; `scripts/dev/eval_run.py <dir>` turns that into deterministic metrics and `scripts/dev/compare.py <dir>...` lines several runs up (the contract is in each script's header).

## Testing

```bash
# Whole gate: ruff check + format, bash -n, shellcheck, bats tests/, pytest with the coverage floor
# (tool selection and versions: .claude/verify.md)
.claude/verify.sh
# Commit boundary: the staged .py / .sh files only
.claude/verify.sh --staged
# bats only
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
# - E2E mock: per-line flow (cwd = repo, prompt injection), the ecosystem execution form
#   (cwd = state/<line>, ecosystem protocol, --safe-mode), retry, receipt-driven report gate
#   (article / brief / quiet / hold / missing receipt / mismatch), call 2 verification tally
# - lib/*.sh units: env sanitize, atomic lock, real auth probe, exit classify
# - Docs: no copied config values or line names (test-docs.bats)
# - pytest: every dr_pipeline.py subcommand, scripts/dev/
```

## Claude Code CLI Flags

### Call 1 — research run (Opus, per picked line: the rotation window's `lines_per_day` lines + every daily line)

The run is invoked with `cd "$TARGET_REPO"`; a `mode = "ecosystem"` line has no repo and is invoked with `cd "state/<line>"` instead (ADR-0018). `--safe-mode` keeps the cwd's CLAUDE.md out of the context, so the repo protocol reads the repo's CLAUDE.md / AGENTS.md explicitly in Step 3b, after the question is chosen.

| Flag | Value | Purpose |
|------|-------|---------|
| `-p` | Per-line prompt (line brief from `dr_pipeline.py line-brief`, recent commit subjects from `repo-activity` on repo lines, the allowed write paths drawn from the `WRITE_PATHS` array, this line's past questions from `past-themes` — ecosystem lines also get the other lines' recent titles — and the report template) | Non-interactive mode |
| `--max-budget-usd` | `[billing] call1_max_usd` (api mode only) | Per-call spend cap |
| `--safe-mode` | every line (both calls and the auth probe, ADR-0019) | The operator's `~/.claude` CLAUDE.md / rules / skills / plugins / hooks / MCP and the cwd's CLAUDE.md are kept out of the run (`-p` and `--append-system-prompt-file` still apply under safe mode, verified 2026-09-21). Safe mode does not switch off permissions — the boundary is `--disallowedTools` |
| `--tools` | `CALL1_TOOLS` | The built-in tool set the run starts with |
| `--permission-mode` | `default` | Use default permission handling |
| `--append-system-prompt-file` | `prompts/repo-research-protocol.md`, or `prompts/ecosystem-research-protocol.md` when `mode = "ecosystem"` | Inject the research protocol while preserving defaults |
| `--disallowedTools` | `DISALLOWED_TOOLS` (`Bash,Task,NotebookEdit` + `Read` denies on `~/.claude/**`, `~/.claude.json`, `~/.codex/**`, the credential stores under `$HOME`, `**/logs/episodes/**`, and the `[billing] env_file` directory) + `Edit` denies on `state/<line>/brief.md`, `state/<line>/playbook.md` and `past_topics.json`; repo lines add `state/<line>/watched-sources.md` / `watched-archive.md`, ecosystem lines add `state/<line>/.claude/**`, `CLAUDE.md`, `.mcp.json` (absolute paths) | Allow rules are additive (under the user's `defaultMode: auto` unlisted tools go through), so the boundary is written as denies and every path taken off the write targets is denied as well. Safe mode drops the user hooks that guarded the harness and episode logs, and WebFetch can send data out, hence the `Read` denies. On an ecosystem line the cwd is model-writable and a `.claude/settings.json` there would be read as project settings on the next run (ADR-0018) |
| `--allowedTools` | `WebSearch,WebFetch,Read,Glob,Grep` + `Edit(//abs)` for each `WRITE_PATHS` entry: the vault report dir, `state/<line>/pending.md`, `state/<line>/runs/**`; ecosystem lines add `state/<line>/watched-sources.md` and `watched-archive.md` | Repo stays read-only at the permission layer. An `Edit(path)` rule also lets `Write` create that path (`Write(path)` rules are not consulted). `past_topics.json` is not a write target: the script appends it from the receipt after the gate (`past-topics-append`) |
| `--max-turns` | `CALL1_MAX_TURNS` (55) | Limit for research depth. The result JSON's `num_turns` is counted differently (live runs have succeeded with `num_turns` above it), so a cap hit shows as `subtype: error_max_turns`, not as `num_turns` |
| `--model` | `opus` | Rotation frees the daily budget for a single high-quality report (ADR-0010) |
| `--output-format` | `json` | Structured output with metadata (fed to metrics) |
| `--no-session-persistence` | - | Fresh context each run |

### Call 2 — verification + clarity (Sonnet by default, per line that ended as article or brief)

| Flag | Value | Purpose |
|------|-------|---------|
| `-p` | Paths of the note, the evidence file (read-only), and `runs/{date}.verify.json` — the note and `verify.json` are the only two writable files | Non-interactive mode |
| `--max-budget-usd` | `[billing] call2_max_usd` (api mode only) | Per-call spend cap |
| `--safe-mode` / `--tools` | `CALL2_TOOLS` | Same launch form as call 1. daily-research's own CLAUDE.md is not loaded either; the verification protocol and the template carry the writing rules |
| `--permission-mode` | `default` | Use default permission handling |
| `--append-system-prompt-file` | `prompts/verification-protocol.md` | Inject clarity (Step A) then source verification (Step B) |
| `--allowedTools` | `Read,WebFetch` + `Edit` of the day's note and `runs/{date}.verify.json` | Only the note and the verification result can be written |
| `--disallowedTools` | `DISALLOWED_TOOLS` (the same list as call 1: `Bash,Task,NotebookEdit` + the `Read` denies) + `WebSearch` + `Edit(state/<line>/pre-verify/**)` | Verification re-fetches the sources in the evidence file and the ソース section; it starts no new search. The before-copy that verify-diff compares against stays out of reach |
| `--max-turns` | `30` | Enough depth to WebFetch every claim |
| `--model` | `[verification] model` (default `sonnet`) | Raise to opus if misses become visible |

The day's `verify.json` is removed before call 2 starts and read back run-scoped (newer than `$LOCK_DIR/pid`). When the same line's call 1 ended with an auth / billing error, call 2 does not start and the note stays `unverified`.

**Note**: All `claude -p` calls use `< /dev/null` stdin redirect — calls 1 and 2 via the `run_claude()` wrapper, the auth probe in `real_auth_probe()` itself. This prevents MCP stdio communication from conflicting with terminal stdin, which was a root cause of past MCP hangs.

## Architecture Notes

The per-repo single-pass design replaced the earlier central 2-pass (Opus theme selection → Sonnet research) pipeline on 2026-08-04: theme selection through synced concept graphs converged on corroboration surveys, while the operational context that knows what to advance lives inside each repo (ADR-0008).

The research run is bounded two ways: `--max-turns 55` and a 25-minute external timeout (`CLAUDE_TIMEOUT=1500` via `run_claude()`, requires coreutils `timeout`). `classify_exit` (`lib/claude.sh`) sorts each result: `E_TRANSIENT` (timeout) and `E_FATAL` are retried once, except when attempt 1 already left a report or receipt — that goes straight to the gate. `E_AUTH` (401; in api mode also 403) and, in api mode, `E_BILLING` (429 / credit balance) stop this line and the remaining lines without a retry, since the same auth or account would fail everywhere; `E_BUDGET` (the per-call `--max-budget-usd`) goes to the gate without a retry. Lines finished before the stop keep their results. When the stop leaves picked lines unstarted, the day ends as `E_PARTIAL` (exit 1) even if no line failed the gate (`E_NO_REPORT` if none passed it); the unstarted lines are logged as `Lines not started:` and listed under 未実行 in the notification. An error in the last picked line leaves nothing unstarted, so the day's class follows the gate alone.

The report-existence gate (ctl-015) reads the run receipt `state/<line>/runs/{date}.json`: a missing or invalid receipt fails the line, `article` / `brief` require a run-scoped report, and `quiet` / `hold` pass without a file. Run scope is decided with `find -newer "$LOCK_DIR/pid"` because bash 3.2's `-nt` only has second resolution. A receipt claiming quiet/hold while a report exists loses to the file (file wins) and is counted as `mismatch`; a quiet/hold with `reason_code = fetch_failed` or zero web searches is counted as `suspect`.

Call 2 (verification + clarity, ADR-0017) runs after the gate: a fresh-context process (`--max-turns 30`, `CLAUDE_TIMEOUT=1200`, `--allowedTools` = Read + WebFetch + Edit of the day's note and `runs/{date}.verify.json`, with WebSearch added to `--disallowedTools`) reads the finished note as a first-contact reader, fixes comprehension stumbles, and then checks every claim in the evidence file against its source. Its failure is fail-open: the log records `WARN: clarity pass failed`, the unverified (or, on timeout, partially revised) note survives, and `FINAL_EXIT` is unaffected — but the line is reported as `unverified` in the metrics and the notification. An auth / billing error in call 2 (`E_AUTH` / `E_BILLING`) also stops the remaining lines, as in call 1. Before call 2 the script copies the note to `state/<line>/pre-verify/{date}.md` (outside every model write path; the path is removed first and must end up a regular file); after call 2, `dr_pipeline.py verify-diff` compares the two and logs `VERIFY_DIFF`, so call 2's real edits are recorded independently of its own report.

`metrics.jsonl` keeps the pre-ADR-0008 record shape for compatibility with `expect-check` / `/dr-review`: the research run JSON is aggregated into the `pass2` field, `pass1` is always `None`, `fallback_used` means "a retry occurred" (`pass2` sums every attempt), `source` is `live` or `test` (runs under `DR_FORCE_TRACK` / `DR_ONLY_TRACK` are recorded as `test` and excluded from `expect-check` / `/dr-review` aggregation), and `clarity_pass` records call 2's `{ran, ok, cost, turns, ...}` (the label is kept for compatibility; what it measures is the verification + clarity pass). Each record also carries `line_states {article, brief, quiet, hold, mismatch, suspect, unverified}` (always emitted, zeros included) and `verification {supported, partial, unsupported, unverifiable, edits, lines_verified}` (`None` on a day with no VERIFY line; on a day with VERIFY_DIFF lines it also carries verify-diff's summed `diff_*` counts and `diff_lines`, the number of lines diffed). Verdicts themselves are never stored — the eval is in-loop (ADR-0010) and only the verification tally survives.

## Persistent Memory Layer

A Mem0 Cloud MCP integration was merged on 2026-02-26 but remained in zero-operation state for 32 days due to a missing `.mcp.json` and a non-functional health check. It was removed on 2026-05-23. Its successor, the local JSON-LD concept cluster graph (`graph.jsonld`), was itself frozen on 2026-08-04 (ADR-0008) — it receives no more increments and is kept as a readable archive. Persistent working state lives in `state/<line>/` (the operator's static brief, pending, the ecosystem lines' watched-sources and watched-archive, the runs/ evidence file, receipt and verification result, and call 2's pre-verify copy) and `past_topics.json` (appended by the script from each receipt after the gate), both local files that fail loudly.
