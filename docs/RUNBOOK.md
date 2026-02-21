# Runbook

> Operational procedures for the daily-research automation system.

## Deployment

### Initial Setup

```bash
# 1. Clone / navigate to project
cd /path/to/daily-research

# 2. Make scripts executable
chmod +x scripts/daily-research.sh
chmod +x scripts/eval-run.sh
chmod +x scripts/check-auth.sh

# 3. Verify auth
./scripts/check-auth.sh

# 4. Create your plist from template
cp com.example.daily-research.plist com.daily-research.plist
# Edit com.daily-research.plist: replace YOUR_USERNAME with your macOS username

# 5. Create launchd symlink
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
daily-research.sh
├── Pass 1: Opus theme selection (--max-turns 15, stream-json)
│   ├── Success → Pass themes to Sonnet
│   └── Failure → Sonnet fallback (handles theme selection + research)
├── Pass 2: Sonnet research & writing (--max-turns 40)
└── Evaluation: LLM-as-Judge (non-fatal, 6 dimensions x Opus)
    └── Scores appended to evals/scores.jsonl
```

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
| Reports generated | `ls <vault_path>/daily-research/$(date +%Y-%m-%d)_*` | 2 files |
| Eval scores saved | `grep "$(date +%Y-%m-%d)" evals/scores.jsonl \| wc -l` | 2 entries |

### Log Messages Reference

| Message | Meaning |
|---------|---------|
| `SUMMARY Pass1: cost=... turns=... duration=...` | Pass 1 execution statistics (cost, turns, duration, tokens) |
| `Pass 1 completed: themes selected by Opus` | Opus theme selection succeeded |
| `Pass 1 themes: tech="...", personal="..."` | Selected themes logged for reference |
| `WARN: Pass 1 failed (exit code N), falling back to Sonnet` | Opus failed, Sonnet will handle everything |
| `WARN: Pass 1 output failed JSON validation` | Opus returned invalid JSON, Sonnet fallback |
| `Fallback: Sonnet handles theme selection + research` | Sonnet is doing all work (normal fallback behavior) |
| `SUMMARY Pass2: cost=... turns=... duration=...` | Pass 2 execution statistics |
| `SUMMARY Total: cost=... duration=...` | Combined cost/duration across both passes |
| `Completed successfully` | Both passes completed |
| `[eval] Evaluation start: DATE=...` | Evaluation framework started |
| `[eval] Found N report(s)` | Number of reports found for evaluation |
| `[eval] Saved: total=N/30 duration=Ns` | Evaluation score saved successfully |
| `WARN: Evaluation failed (non-fatal)` | Evaluation failed but pipeline continues |

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

### 4. Pass 1 (Opus) Consistently Failing

**Symptoms**: Log always shows `WARN: Pass 1 failed`, Sonnet fallback runs every day.

**Causes**:
- Opus rate limit hit (Claude Max plan quota)
- Network issues during WebSearch
- `--max-turns 15` too low for complex theme selection

**Fix**: Check the specific exit code in the log. Pass 1 failure is non-critical (Sonnet handles it). If persistent, consider increasing `--max-turns` or checking plan quota usage.

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

### 7. Duplicate Topics

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
| AM 5:00 | `daily-research.sh` runs via launchd |

If Mac was asleep at 5:00, launchd runs the job on wake (behavior of `StartCalendarInterval`).

## Cost

| Component | Model | Est. Cost/Run |
|-----------|-------|---------------|
| Pass 1: Theme selection | Opus | ~$0.30 |
| Pass 2: Research & writing | Sonnet | ~$1.50 |
| Evaluation (2 reports x 6 dims) | Opus | ~$0.50 |
| **Total** | | **~$2.30** |

With Claude Max plan, these costs are covered by the subscription. No per-token charges.
