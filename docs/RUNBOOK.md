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

# Direct execution (must be in a separate terminal from Claude Code)
./scripts/daily-research.sh
```

## Architecture

```
daily-research.sh (05:00)
├── Lock acquisition (atomic mkdir)
├── Auth probe (real OAuth check)
├── Config schema check (legacy pre-ADR-0008 schema fails fast)
├── rotation-pick — deterministic selection of today's lines: one rotated line
│   (epoch day % non-daily line count, ADR-0010) + every `daily = true` line (ADR-0011)
├── Call 1: claude -p, cwd = the picked line's target_repo (Opus, --max-turns 55,
│   25-min timeout, one retry on transient failure; 401 aborts)
│   ├── Read repo context (CLAUDE.md auto-loaded + context_files) + state/<line>/
│   ├── Diff-first pass over watched sources · theme selection (2–3 candidates →
│   │   binary checklist → theme_rank verdict, ADR-0010) · research with citation gate
│   ├── Premise-challenge pass (counter-evidence is mandatory)
│   └── Write free-form explanatory note → vault · update state + past_topics.json
├── ctl-015 report-existence gate ({date}_{track}_*.md in vault)
├── Call 2: fresh-context clarity revision (Sonnet, no research context, Edit limited
│   to the day's note; failure is fail-open — unrevised note survives, ADR-0010)
├── ctl-016 deterministic report lint (fixed sections 機会メモ / ソース, synced to report-template.md)
├── Pass 3: Obsidian wiki ingest (vault-side script, non-fatal)
└── metrics.jsonl append (incl. clarity_pass record) + /dr-review age check
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
| Reports generated | `ls <vault_path>/daily-research/$(date +%Y-%m-%d)_*` | One file per configured line |

### Log Messages Reference

| Message | Meaning |
|---------|---------|
| `Auth probe passed` | Real OAuth probe succeeded |
| `Config schema check passed` | `config.toml` matches the current (ADR-0008) schema |
| `=== Line: <track> (<repo path>) ===` | Per-line run starting with that repo as cwd |
| `SUMMARY Run(<track>): cost=... turns=... duration=...` | Per-line run statistics (cost, turns, duration, tokens) |
| `WARN: Line <track> failed (..., exit N) — retrying once` | Transient failure; the single retry is starting |
| `ERROR: Line <track> returned 401 — aborting remaining lines` | Auth expired mid-run; remaining lines are skipped, finished lines' results are kept |
| `Line <track> report gate passed (N report)` | ctl-015: the line's `{date}_{track}_*.md` exists in the vault |
| `WARN: Line <track> produced no ..._*.md (ctl-015)` | The line ran but wrote no report — counted as failed |
| `Report existence gate passed: N report(s)` | Every picked line passed ctl-015 (partial failure logs `Failed (E_PARTIAL: ...)` instead) |
| `WARN: clarity pass failed ...` | Call 2 clarity failed (fail-open — the run still succeeds) |
| `WARN: report lint hard fail (ctl-016): ...` | Deterministic lint found a missing sources section / zero citations |
| `Completed successfully` | All of the day's picked lines completed and passed the report gate |

## Common Issues and Fixes

### 1. OAuth Token Expired

**Symptoms**: Log shows `ERROR: Claude authentication may have expired`. macOS notification appears.

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

**Symptoms**: Log shows `ERROR: Another instance is running (PID: ...)`.

**Cause**: Previous run is still active, or crashed without cleanup.

**Fix**:
```bash
# Check if the PID is actually running
ps aux | grep daily-research

# If no process is running, remove stale lock
rm -f .daily-research.lock
```

### 4. A Line Consistently Failing

**Symptoms**: Log shows `WARN: Line <track> failed after retry` or `WARN: Line <track> produced no ..._*.md (ctl-015)` on consecutive days.

**Causes**:
- Rate limit hit (Claude Max plan quota) or network issues during WebSearch
- The 25-minute per-line timeout expiring on an unusually deep run
- The line's `target_repo` path in `config.toml` missing or moved

**Fix**: Check the specific exit class in the log (`E_TRANSIENT` / `E_FATAL`). One line failing does not stop the others — their reports still land and get ingested. Verify `target_repo` exists, then re-run the script manually. A 401 (`E_AUTH`) means the OAuth token expired: see issue 1.

### 5. `ANTHROPIC_API_KEY` Set (Per-Token Billing)

**Symptoms**: Unexpected API charges on Anthropic dashboard.

**Cause**: `ANTHROPIC_API_KEY` env var was set, bypassing Max plan.

**Fix**: The script runs `unset ANTHROPIC_API_KEY`. If charges persist, check shell profile (`~/.zshrc`, `~/.bashrc`) for exports.

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

### 8. Duplicate Topics

**Symptoms**: Reports cover the same theme as recent days.

**Cause**: `past_topics.json` not updated properly, or scoring criteria need tuning.

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

Each morning the rotation-picked line plus every `daily = true` line runs (ADR-0010 / ADR-0011) — with one daily line configured that is 2 lines per morning. Per line: Call 1 = one Opus research run (at most 2 invocations with its single retry, 25-min cap) plus Call 2 = one Sonnet clarity revision (15-min cap). With Claude Max plan, model usage is covered by the subscription with no per-token charges; cost and duration are recorded in `metrics.jsonl` for actual measurement.
