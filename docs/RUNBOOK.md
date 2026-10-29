# Runbook

> Operational procedures for the daily-research automation system.

## Deployment

### Initial Setup

```bash
# 1. Clone / navigate to project
cd /path/to/daily-research

# 2. Make scripts executable
chmod +x scripts/daily-research.sh
chmod +x scripts/check-auth.sh

# 3. Verify auth
./scripts/check-auth.sh

# 4. Create your plist from the template (research 05:00)
cp com.example.daily-research.plist com.daily-research.plist
# Edit the plist: replace YOUR_USERNAME with your macOS username

# 5. Create the launchd symlink
ln -sf "$(pwd)/com.daily-research.plist" \
       ~/Library/LaunchAgents/com.daily-research.plist

# 6. Load the job
launchctl load ~/Library/LaunchAgents/com.daily-research.plist

# 7. Verify registration
launchctl list | grep daily-research
```

### Updating After Changes

```bash
# Reload plist after editing schedule or paths
launchctl unload ~/Library/LaunchAgents/com.daily-research.plist
launchctl load ~/Library/LaunchAgents/com.daily-research.plist
```

Config/prompt changes (`config.toml`, `prompts/*`, `templates/*`) take effect on next run without reload.

### Manual Trigger

```bash
# Via launchd
launchctl start com.daily-research

# Direct execution — also works from inside a Claude Code session (lib/env.sh unsets CLAUDECODE)
./scripts/daily-research.sh
# Test seams: DR_FORCE_TRACK=<line> (run one line even when today's window does not include it, today's date),
# DR_ONLY_TRACK=<line> (only that line among today's picks), DR_DATE=YYYY-MM-DD (fix the rotation date)
```

## Architecture

```
daily-research.sh (05:00)
├── Lock acquisition (atomic mkdir)
├── Billing setup ([billing]: api = ANTHROPIC_API_KEY from env_file, subscription = OAuth)
├── Auth probe (one real Haiku call on that billing path)
├── Config schema check (legacy pre-ADR-0008 schema fails fast)
├── rotation-pick — deterministic selection of today's lines: a rotation window
│   (start = date.toordinal() × K mod N, then K consecutive lines, K = [general]
│   lines_per_day — proleptic Gregorian ordinal, ADR-0010 / ADR-0017) + every `daily = true` line (ADR-0011)
├── Call 1: claude -p, cwd = the picked line's target_repo (Opus, --max-turns 55,
│   25-min timeout, one retry on transient failure; 401 aborts)
│   [api mode: a spend gate before each line (day / month caps), --max-budget-usd per call,
│    each call's cost appended to state/api-spend.jsonl; 429 / credit balance stops the run]
│   [mode = "ecosystem" lines have no target_repo: cwd = state/<line>,
│    prompts/ecosystem-research-protocol.md, plus --safe-mode — ADR-0018]
│   ├── Read a short context (line brief + state/<line>/brief.md + question history + pending.md)
│   ├── Diff-first pass over watched sources + wide search · pick one of 3–6 candidate
│   │   questions (or quiet / hold) · read context_files after the pick · research with
│   │   citation gate · evidence file runs/{date}.md
│   ├── Write explanatory note (no fixed headings; article ≤ 3,000 chars / brief 300–600)
│   │   → vault (nothing is written on a quiet / hold day)
│   └── Write the run receipt runs/{date}.json right after the note · update state + past_topics.json
├── ctl-015 report-existence gate (receipt-driven: missing / invalid receipt fails the line,
│   article & brief require {date}_{track}_*.md in the vault, quiet & hold pass without a file)
├── Call 2: fresh-context verification + clarity (Sonnet by default, --max-turns 30, 20-min
│   timeout, no research context, Read + WebFetch, Edit limited to the day's note and
│   runs/{date}.verify.json, WebSearch denied; failure is fail-open — the unverified note
│   survives, ADR-0017)
├── ctl-016 deterministic report lint (fixed sections 機会メモ / ソース, synced to
│   report-template.md; kind: brief is exempt from the 機会メモ and length soft checks)
├── Pass 3: Obsidian wiki ingest (vault-side script, non-fatal)
└── metrics.jsonl append (incl. clarity_pass / line_states / verification) + /dr-review age check
```

(The 07:00 morning-brief.sh was retired in ADR-0009 — notes are now reading
material that requests no approval.)

## Monitoring

### Log Locations

| Log | Path | Retention |
|-----|------|-----------|
| Application log | `logs/YYYY-MM-DD.log` | 30 days (auto-rotated) |
| launchd stdout | `logs/launchd-stdout.log` | Manual cleanup |
| launchd stderr | `logs/launchd-stderr.log` | Manual cleanup |

### Daily Checks

```bash
# Check today's log
cat logs/$(date +%Y-%m-%d).log

# Check if report was generated (use your vault_path from config.toml)
ls -la "/path/to/your/obsidian/vault/daily-research/"

# Check launchd job status
launchctl list | grep daily-research
# Exit code 0 = last run succeeded
```

### Health Indicators

| Check | Command | Expected |
|-------|---------|----------|
| Job registered | `launchctl list \| grep daily-research` | Row with exit status 0 |
| Auth valid | `./scripts/check-auth.sh` | "OK: Claude authentication is valid" |
| Today's log exists | `ls logs/$(date +%Y-%m-%d).log` | File exists |
| Log shows success | `grep "Completed successfully" logs/$(date +%Y-%m-%d).log` | Match found |
| Reports generated | `ls <vault_path>/daily-research/$(date +%Y-%m-%d)_*` | One file per line that ended as article or brief (3 lines a day by default; quiet / hold lines write no file) |
| Receipts present | `ls state/*/runs/$(date +%Y-%m-%d).json` | One file per *picked* line (what the gate reads) |
| Verification ran | `grep "VERIFY " logs/$(date +%Y-%m-%d).log` | One line per article / brief line (`"ran": true`) |
| Today's breakdown | `grep "Line states:" logs/$(date +%Y-%m-%d).log` | `article=N brief=N quiet=N hold=N` plus the published / quiet / unverified breakdown |

### Log Messages Reference

| Message | Meaning |
|---------|---------|
| `Billing: api (key from …; caps …)` / `Billing: subscription (Max plan OAuth)` | The billing path `[billing] mode` selected |
| `ERROR: billing setup failed — …` | `[billing]` is invalid or (api mode) `env_file` has no `ANTHROPIC_API_KEY`; the run stops before any call (exit 1) |
| `Auth probe passed` | The real auth probe succeeded |
| `ERROR: Auth probe failed (<mode>) — status=… result=…` | The probe failed (expired OAuth, or in api mode a rejected key / low credit / 429); the run stops before any line (exit 1) |
| `WARN: API spend gate stopped the run (month $… / $…, day $… / $…, need $… per line) — stopping remaining lines` | api mode: the remaining budget can't cover one more line, or (after an `ERROR: … spend …` line) the ledger could not be written or read; the rest are skipped and named in `Lines not started: …` |
| `ERROR: Line <track> hit a billing/rate-limit error — aborting remaining lines, no retry` | api mode: 429 or credit balance too low (`E_BILLING`) |
| `WARN: Line <track> reached --max-budget-usd $… — no retry, going to gate` | The per-call cap stopped call 1; whatever it wrote goes to the gate |
| `API spend: today $… / $…, month $… / $…` | api mode: totals from `state/api-spend.jsonl` after the run |
| `ERROR: Another instance is running. Skipping.` | Lock directory `.daily-research.lock/` is held by a live PID |
| `Config schema check passed` | `config.toml` matches the current (ADR-0008) schema |
| `Rotation pick: a, b, c (ADR-0010/0017)` | The rotation window picked for today |
| `Today's lines: N` | How many lines run today (`lines_per_day` + any daily lines) |
| `=== Line: <track> (<repo path>) ===` | Per-line run starting with that repo as cwd (an ecosystem line has no repo and logs `no target repo`) |
| `Line <track> mode: ecosystem (cwd = state/<track>, safe mode)` | The line is `mode = "ecosystem"`: it runs from its state directory under the ecosystem protocol with `--safe-mode` (ADR-0018) |
| `SUMMARY Run(<track>): cost=... turns=... duration=...` | Per-line run statistics (cost, turns, duration, tokens) |
| `WARN: Line <track> failed (..., exit N) — retrying once` | Transient failure; the single retry is starting |
| `ERROR: Line <track> returned 401 — aborting remaining lines (…)` | Auth failed mid-run (401 / 403: expired OAuth or rejected key); remaining lines are skipped, finished lines' results are kept |
| `Line <track> state: <status>` | The content state the receipt declared (article / brief / quiet / hold) |
| `Line <track> report gate passed` | ctl-015: the line delivered what its receipt declared (article / brief: `{date}_{track}_*.md` exists in the vault; quiet / hold: no file needed) |
| `WARN: report gate failed for line <track> — no <date>_<track>_*.md (ctl-015)` | The receipt says article / brief but no report exists — counted as failed |
| `WARN: report gate failed for line <track> — ... receipt ... (ctl-015)` | The run-scoped receipt is missing or invalid — counted as failed (a run that died before writing it) |
| `Report existence gate passed: N report(s)` | Every picked line passed ctl-015 (partial failure logs `Failed (E_PARTIAL: ...)` instead) |
| `Line states: article=N brief=N quiet=N hold=N (...)` | Today's breakdown; the published / quiet / unverified / suspected-fetch-failure segments appear only when non-empty |
| `VERIFY <track>: {...}` | Call 2's verification tally (supported / partial / unsupported / unverifiable / edits / ran) |
| `WARN: clarity pass failed ...` | Call 2 (verification + clarity) failed (fail-open — the run still succeeds and the line is counted `unverified`) |
| `WARN: report lint hard fail (ctl-016): ...` | Deterministic lint found a missing sources section / zero citations |
| `Completed successfully` | All of the day's picked lines completed and passed the report gate (including an all-quiet day) |

### Notifications

| Notification | Meaning |
|---------|------|
| `今朝のリサーチレポートが完成しました (今朝: … / 更新なし: … / 未検証: …)` | All lines succeeded and at least one report was published |
| `今朝は更新なし (更新なし: …)` | Every line ended quiet / hold (a success) |
| `リサーチが一部失敗しました (今朝: … / 更新なし: … / failed: …)。ログを確認してください。` | E_PARTIAL — the failed lines are named |

未検証 (unverified) lists lines whose call 2 failed or left no verify.json; their notes are published anyway. A quiet / hold flagged as a suspected fetch failure (zero web searches, or `reason_code = fetch_failed`) points at a network-side problem rather than a quiet day.

## Common Issues and Fixes

### 1. OAuth Token Expired (subscription mode)

**Symptoms**: Log shows `ERROR: Auth probe failed (subscription) — …`. macOS notification appears.

**Cause**: Claude OAuth token expires approximately every 4 days.

**Fix**:
```bash
# Open Claude CLI interactively to refresh token
claude
# Wait for authentication prompt, complete it, then exit
# Verify:
./scripts/check-auth.sh
```

**Prevention**: Run `claude` interactively at least twice per week.

### 2. `claude` Command Not Found

**Symptoms**: Log shows `ERROR: claude command not found in PATH`.

**Cause**: PATH in launchd environment doesn't include Claude CLI location.

**Fix**:
```bash
# Check where claude is installed
which claude

# Ensure that path is in daily-research.sh PATH export
# AND in the plist EnvironmentVariables PATH
```

### 3. Lock File Prevents Execution

**Symptoms**: Log shows `ERROR: Another instance is running. Skipping.`

**Cause**: Previous run is still active, or crashed without cleanup.

**Fix**:
```bash
# The lock is a DIRECTORY holding a pid file
cat .daily-research.lock/pid
ps aux | grep daily-research

# If no process is running, remove the stale lock directory
# (the script also steals a lock whose PID is dead on its next start)
rm -rf .daily-research.lock
```

### 4. A Line Consistently Failing

**Symptoms**: Log shows `WARN: Line <track> failed after retry` or `WARN: report gate failed for line <track> — ... (ctl-015)` on consecutive days.

**Causes**:
- Rate limit hit (the plan's quota in subscription mode; in api mode a 429 stops the run instead, see issue 5) or network issues during WebSearch
- The 25-minute per-line timeout expiring on an unusually deep run
- The line's `target_repo` path in `config.toml` missing or moved (a `mode = "ecosystem"` line has no `target_repo` — it runs from `state/<line>`, which the script creates, and logs `Line <track> mode: ecosystem (cwd = state/<track>, safe mode)`)

**Fix**: Check the specific exit class in the log (`E_TRANSIENT` / `E_FATAL`). One line failing does not stop the others — their reports still land and get ingested; the day's final class is then `E_PARTIAL` (exit 1, `=== Failed (E_PARTIAL:<lines>, exit code 1) ===`), while `E_NO_REPORT` is reserved for a day where no line passed the gate (ADR-0011 / ADR-0017 — a day where every line ended quiet is a success, not `E_NO_REPORT`). Verify `target_repo` exists, then re-run the script manually. A 401 (`E_AUTH`) means the OAuth token expired (issue 1) or, in api mode, the key was rejected (issue 5).

### 5. API Mode: Rejected Key, Credit, Rate Limit or Spend Cap

**Symptoms**: `ERROR: Auth probe failed (api) — …`, `hit a billing/rate-limit error`, or `API spend gate stopped the run` in the log, with a macOS notification.

**Causes and fixes**:
- `status=401` / `403`: the key in `env_file` is wrong or revoked. Replace it there (never in the repo), then run `./scripts/check-auth.sh`.
- `Your credit balance is too low`: add credit on platform.claude.com.
- `status=429`: rate limit. The run stops on purpose instead of backing off (a burst of rate limits is a policy signal). Re-run later by hand.
- `API spend gate stopped the run`: the day's or month's remaining budget is below one line's reserve (`call1_max_usd + call2_max_usd`). Check `state/api-spend.jsonl`; raise the caps in `[billing]` only if the credit covers it.

The billing path never changes on its own: in subscription mode an `ANTHROPIC_API_KEY` exported in your shell is dropped, and in api mode only the key in `env_file` is used.

### 6. Reports Not Appearing in Obsidian

**Symptoms**: Script completes successfully but reports aren't visible in Obsidian.

**Cause**: iCloud sync delay, or vault path changed.

**Fix**:
```bash
# Verify vault path matches config.toml
grep vault_path config.toml

# Check if files exist on disk (use your vault_path)
ls "/path/to/your/obsidian/vault/daily-research/"

# Force iCloud sync: open Files app on iOS or wait
```

### 7. Slow Execution or Hangs Due to Plugins

**Symptoms**: A per-line run burns most of its 25-minute timeout on startup, or hangs indefinitely.

**Cause**: Claude Code plugins (pyright, swift-lsp, hookify, mgrep, claude-mem, etc.) installed globally. Each `claude -p` invocation initializes all plugin MCP servers, adding significant startup overhead.

**Fix**: Create `.claude/settings.json` in the project root to disable plugins for this project:
```json
{
  "enabledPlugins": {
    "plugin-name@marketplace": false
  }
}
```

List your installed plugins with `claude plugin list`, then set each to `false`. This only affects this project; other projects and interactive sessions are unaffected.

**Verification**:
```bash
# After disabling plugins, check that no plugin MCP servers start:
ps aux | grep -E "pyright|sourcekit|claude-mem|sequential|japanese|ableton"
```

**Note**: There is no blanket "disable all plugins" option yet. Each plugin must be listed explicitly. See [tracking issue](https://github.com/anthropics/claude-code/issues/20873).

### 8. Duplicate Questions

**Symptoms**: Reports answer the same question with the same answer as recent days (the same topic under a different question is fine).

**Cause**: `past_topics.json` not updated properly (the run's question selection depends on the past questions and their `answer_scope` it feeds), or `state/<line>/brief.md` not keeping its open questions current.

**Fix**:
```bash
# Check past_topics.json
cat past_topics.json | python3 -m json.tool

# Restore from backup if corrupted
cp past_topics.json.bak past_topics.json
```

## Rollback Procedures

### Revert Configuration Changes

```bash
git diff config.toml
git checkout config.toml
```

### Restore past_topics.json

```bash
cp past_topics.json.bak past_topics.json
```

### Disable Automation

```bash
launchctl unload ~/Library/LaunchAgents/com.daily-research.plist
```

### Re-enable Automation

```bash
launchctl load ~/Library/LaunchAgents/com.daily-research.plist
```

## Schedule

| Time | Action |
|------|--------|
| AM 5:00 | `daily-research.sh` runs via launchd (per-line research) |

If Mac was asleep at the scheduled time, launchd runs the job on wake (behavior of `StartCalendarInterval`).

## Cost

Each morning the `lines_per_day` lines of the rotation window plus every `daily = true` line run (ADR-0010 / ADR-0011 / ADR-0017). The author's config as of 2026-10-29 runs two rotating lines, plus `desire` as a daily line until 2026-11-03, so three lines a day until then and two after. Per line: Call 1 = one Opus research run (at most 2 invocations with its single retry, 25-min cap) plus Call 2 = one verification + clarity pass (Sonnet by default, 20-min cap); a line that ends quiet or hold skips Call 2.

**Who pays** is `[billing] mode` in `config.toml` (`scripts/lib/billing.sh`; the contract is `[billing]` in `scripts/lib/dr_pipeline.py`):

| mode | Auth | Billing | Limits |
|---|---|---|---|
| `subscription` (default) | Claude Code login (OAuth) | No per-token charge on a Max plan; counts against the plan's usage limits | The plan's own limits. Any `ANTHROPIC_API_KEY` in the environment is dropped |
| `api` (author's setting since 2026-10-29) | `ANTHROPIC_API_KEY` read from `env_file` (author: `~/.config/jrp/env`, shared with jev-research-pipeline) | Every call is billed to the Claude API | `--max-budget-usd` per call (`call1_max_usd` 4, `call2_max_usd` 1.5); a line starts only if the day's and the month's remaining budget both cover call1 + call2 (`daily_cap_usd` 15, `monthly_cap_usd` 190 against $200/month of API credit). Otherwise the remaining lines are skipped with a notification; a day where no line started ends as `E_BUDGET` (exit 1) |

In `api` mode every call's cost (the `total_cost_usd` Claude Code reports, including the auth probe) is appended to `state/api-spend.jsonl`; the caps read that file, and the day's totals are logged as `API spend: today $… / $15, month $… / $190`. A 429, a too-low credit balance or a rejected key stops the remaining lines without a retry (`E_BILLING` / `E_AUTH`).

**Estimate.** The 2026-09-15–22 runs (Opus 5 / Sonnet 5, 25 lines) averaged $3.32 for call 1 and $0.60 for call 2. Repriced at the list prices on [platform.claude.com/docs/en/about-claude/pricing](https://platform.claude.com/docs/en/about-claude/pricing) as of 2026-10-29 (Opus 5.5 $4 / $20 per MTok, cache read $0.20; Sonnet 5.5 $2 / $10, cache read $0.10; web search $10 per 1,000) with the same token counts, a line comes to about $2.4–2.9: call 1 ≈ $1.9–2.3 (most of it is re-reading the cached context every turn, about 2.4M cache-read tokens per run), call 2 ≈ $0.45–0.55. That is about $155 a month at two lines a day. The token counts on Opus 5.5 are not yet measured; check `state/api-spend.jsonl` after the first week. Three lines run sequentially in 20–35 minutes (2026-09 runs).
