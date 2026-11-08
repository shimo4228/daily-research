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
launchctl start com.yourname.daily-research   # the Label in your plist

# Direct execution — also works from inside a Claude Code session (lib/env.sh unsets CLAUDECODE)
./scripts/daily-research.sh
# Test seams: DR_FORCE_TRACK=<line> (run one line even when today's window does not include it, today's date),
# DR_ONLY_TRACK=<line> (only that line among today's picks), DR_DATE=YYYY-MM-DD (fix the rotation date)
```

## Architecture

```
daily-research.sh (05:00)
├── Lock acquisition (check and mkdir inside a flock mutex)
├── Billing setup ([billing]: api = ANTHROPIC_API_KEY from env_file, subscription = OAuth)
├── Auth probe (one real Haiku call on that billing path, with --safe-mode like both calls)
├── Config schema check (`dr_pipeline.py tracks`: the legacy pre-ADR-0008 schema and malformed line
│   definitions — e.g. `repos` written as a single table, or an entry without `key` / `target_repo` — fail fast)
├── rotation-pick — deterministic selection of today's lines: a rotation window
│   (start = date.toordinal() × K mod N, then K consecutive lines, K = [general]
│   lines_per_day — proleptic Gregorian ordinal, ADR-0010 / ADR-0017) + every `daily = true` line (ADR-0011)
├── Call 1: claude -p, cwd = the picked line's target_repo (Opus, --effort from [effort].call1, --max-turns 55,
│   25-min timeout, one retry on transient failure; 401 aborts)
│   [api mode: a spend gate before each line (day / month caps), --max-budget-usd per call,
│    each call's cost appended to state/api-spend.jsonl; 429 / credit balance stops the run]
│   [mode = "ecosystem" lines have no target_repo: cwd = state/<line>,
│    prompts/ecosystem-research-protocol.md — ADR-0018; every line runs with --safe-mode — ADR-0019]
│   ├── Read a short context (line brief + state/<line>/brief.md + question history + pending.md)
│   ├── Wide search (an ecosystem line first checks its watched-sources.md watchlist) · pick one
│   │   of 3–6 candidate questions (or quiet / hold) · read context_files after the pick ·
│   │   research with citation gate · evidence file runs/{date}.md
│   ├── Write explanatory note (no fixed headings; article ≤ 3,000 chars / brief 300–600)
│   │   → vault (nothing is written on a quiet / hold day)
│   └── Write the run receipt runs/{date}.json right after the note · update pending.md
│       (an ecosystem line also updates its watchlist, moving dropped rows to watched-archive.md)
├── ctl-015 report-existence gate (receipt-driven: missing / invalid receipt fails the line,
│   article & brief require {date}_{track}_*.md in the vault, quiet & hold pass without a file)
│   → past-topics-append records the question history in past_topics.json from the receipt
├── Call 2: fresh-context verification + clarity (Sonnet by default, --effort from [effort].call2, --max-turns 30, 20-min
│   timeout, no research context, Read + WebFetch, Edit limited to the day's note and
│   runs/{date}.verify.json, WebSearch denied; failure is fail-open — the unverified note
│   survives, ADR-0017; an auth / billing error stops the remaining lines as in call 1)
│   [before: the script copies the note to state/<line>/pre-verify/{date}.md;
│    after: verify-diff compares the two and logs VERIFY_DIFF]
├── Call 3 (only when [audit] enabled; kind: article only): fact audit, ADR-0020 (Opus by default,
│   --effort high, WebFetch + WebSearch only — no Read, no write tool; the note and the evidence file
│   are inlined in the prompt)
│   ├── Stage 1 (--max-turns 40, 10-min timeout): lists only the sentences that contradict a source
│   ├── Stage 2 per candidate, at most 5 (--max-turns 20, 4-min timeout): sees only the sentence,
│   │   the URL and the note's date, and judges it again on its own
│   └── audit-apply (code, not the model): replaces the candidates both stages call a contradiction,
│       when the sentence appears exactly once in the body and the replacement is a small edit that
│       keeps the note's URLs, links, emphasis and headings and adds no markup;
│       state in runs/{date}.audit.json, the note before the audit in state/<line>/pre-audit/{date}.md,
│       logs AUDIT. Any failure is fail-open — the note stays as call 2 left it
├── ctl-016 deterministic report lint (fixed sections 機会メモ / ソース, synced to
│   report-template.md; kind: brief is exempt from the 機会メモ and length soft checks)
├── Pass 3: Obsidian wiki ingest (vault-side script, non-fatal, under an outer timeout = the ingest's own claude
│   limit (`WIKI_INGEST_TIMEOUT`, else the vault default) plus a margin; logged as `Pass 3 outer timeout: …`)
└── metrics.jsonl append (incl. clarity_pass / line_states / verification / event_age_days / effort) + /dr-review age check
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
| Reports generated | `ls <vault_path>/daily-research/$(date +%Y-%m-%d)_*` | One file per line that ended as article or brief (quiet / hold lines write no file) |
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
| `WARN: API spend gate stopped the run (month $… / $…, day $… / $…, need $… per line) — stopping remaining lines` | api mode: the remaining budget can't cover one more line; the rest are skipped and named in `Lines not started: …` (notification: `API 支出の上限に達したため、…`) |
| `WARN: API spend gate could not check the caps (the reason is the ERROR line above) — stopping remaining lines` | api mode: the ledger could not be written or read (or the gate itself failed), so the caps could not be checked; the reason is the `ERROR: … spend …` line just before. The rest are skipped and named in `Lines not started: …` (notification: `API 支出を確かめられなかったため、…`, never the cap wording) |
| `ERROR: API spend gate failed (rc 2): spend-gate: N unreadable line(s) in …: line K (reason), … — cannot check the caps` | api mode: the gate could not total the ledger, so it stops instead of guessing. The message names the first five unreadable lines of `state/api-spend.jsonl` with their reasons and counts the rest as `and N more` (fix or remove those lines); `cannot read …` means the file itself could not be opened |
| `Lines not started: a, b` | Lines the run stopped before starting (spend cap, or an auth / billing error) |
| `ERROR: Line <track> hit a billing/rate-limit error — aborting remaining lines, no retry` | api mode: 429 or credit balance too low (`E_BILLING`) |
| `WARN: Line <track> reached --max-budget-usd $… — no retry, going to gate` | The per-call cap stopped call 1; whatever it wrote goes to the gate |
| `API spend: today $… / $…, month $… / $…` | api mode: totals from `state/api-spend.jsonl` after the run |
| `ERROR: Another instance is running. Skipping.` | Lock directory `.daily-research.lock/` is held by a live `daily-research.sh` process |
| `ERROR: Could not verify the lock (…). Skipping.` | The lock could not be checked, so the run did not start (notification: `ロックを確かめられず実行しませんでした`). The reason in parentheses: the mutex was not free within 10 s, `python3` failed, or the mutex file / lock directory could not be created |
| `Config schema check passed` | `config.toml` matches the current (ADR-0008) schema |
| `ERROR: config.toml schema check failed (the reason is on the line above; see config.example.toml)` | `dr_pipeline.py tracks` rejected `config.toml` (legacy schema, a bad line name, a wrong type for `daily` / `template` / `mode`, an unknown `mode` value, `repos` / `context_files` on a `mode = "ecosystem"` line, a malformed `repos`, or a bad `lines_per_day`); the reason is the line logged just before. The run stops before any line (exit 1) |
| `Effort: call1 <level> (model opus), call2 <level> (model <model>) — passed as --effort` | The `--effort` each call gets (`[effort]`, defaults in code); the same pair is recorded as `effort` in `metrics.jsonl`. The level that runs can be lower (a `maxEffortLevel` or organization cap, or a level the model does not support) |
| `ERROR: [effort] in config.toml is invalid (the reason is on the line above; see config.example.toml)` | `[effort]` has an unknown key or a level outside `low` / `medium` / `high` / `xhigh` / `max`; the reason is the line logged just before. The run stops before any line (exit 1) |
| `Rotation pick: a, b, c (ADR-0010/0017)` | The rotation window picked for today |
| `Today's lines: N` | How many lines run today (`lines_per_day` + any daily lines) |
| `=== Line: <track> (<repo path>) ===` | Per-line run starting with that repo as cwd (an ecosystem line has no repo and logs `no target repo`) |
| `Line <track> mode: ecosystem (cwd = state/<track>)` | The line is `mode = "ecosystem"`: it runs from its state directory under the ecosystem protocol (ADR-0018). Every line runs with `--safe-mode` (ADR-0019) |
| `SUMMARY Run(<track>): cost=... turns=... duration=...` | Per-line run statistics (cost, turns, duration, tokens) |
| `WARN: Line <track> failed (..., exit N) — retrying once` | Transient failure; the single retry is starting |
| `ERROR: Line <track> returned 401 — aborting remaining lines (…)` | Auth failed mid-run (401 / 403: expired OAuth or rejected key); remaining lines are skipped, finished lines' results are kept |
| `ERROR: clarity pass returned an auth error — aborting remaining lines` / `ERROR: clarity pass hit a billing/rate-limit error — aborting remaining lines` | Call 2 met the same error; the remaining lines are skipped as after call 1 |
| `WARN: Line <track> clarity pass skipped after an auth/billing error — note stays unverified` | The line's call 1 ended with an auth / billing error after writing its note; call 2 does not start |
| `Line <track> state: <status>` | The content state the receipt declared (article / brief / quiet / hold) |
| `Line <track> report gate passed` | ctl-015: the line delivered what its receipt declared (article / brief: `{date}_{track}_*.md` exists in the vault; quiet / hold: no file needed) |
| `WARN: Line <track> past_topics.json append failed — history not recorded` | The gate passed but the question history could not be appended from the receipt; the line still succeeds, and `past_topics.json.bak` from the run's start remains |
| `Line <track> pending.md: items A→B, chars C→D` | Items and size of the line's `pending.md` before call 1 and after the gate (headings, bold-led bullets and table rows count as items) |
| `WARN: Line <track> pending.md の項目が <state> の run で N 件増えた (…)` | A run other than hold added more `pending.md` items than its note's dated-deadline opportunities. The protocols add items only for hold questions and dated-deadline opportunities; log only, the line still succeeds |
| `receipt-event-date: WARN … — counted as unknown` | The receipt has no `event_date` (an older receipt) or it is not a calendar date on or before the run date; the line still succeeds and is counted as unknown |
| `Line <track> event_date: <YYYY-MM-DD\|unknown>` | Article / brief only: the date of the note's central event, from the receipt's `event_date` (H17, freshness measurement). Recorded as `event_age_days` in metrics; it affects neither the gate nor selection |
| `WARN: report gate failed for line <track> — no <date>_<track>_*.md (ctl-015)` | The receipt says article / brief but no report exists — counted as failed |
| `WARN: report gate failed for line <track> — ... receipt ... (ctl-015)` | The run-scoped receipt is missing or invalid — counted as failed (a run that died before writing it) |
| `Report existence gate passed: N report(s)` | Every picked line passed ctl-015. A day with a failed line, or one where an auth / billing error left picked lines unstarted, logs `=== Failed (E_PARTIAL:<failed lines>, exit code 1) ===` instead when at least one line passed the gate, and `=== Failed (E_NO_REPORT:<failed lines>, exit code 1) ===` when none did (the list after the colon is empty when only the unstarted lines are missing) |
| `Line states: article=N brief=N quiet=N hold=N (...)` | Today's breakdown; the published / quiet / unverified / suspected-fetch-failure segments appear only when non-empty |
| `VERIFY <track>: {...}` | Call 2's verification tally (supported / partial / unsupported / unverifiable / edits / ran) |
| `VERIFY_DIFF <track>: {...}` | What call 2 actually changed, compared against the before-copy `state/<line>/pre-verify/{date}.md` that the script writes before call 2: changed spans, characters added / removed, removed sentences, numbers added / removed, new URLs, and whether the frontmatter, 機会メモ or ソース section changed. Summed into the metrics record's `verification` |
| `WARN: Line <track> clarity pass: …` | verify-diff found an edit the verification protocol forbids (frontmatter, 機会メモ, ソース beyond `(未解決 …)` marks, a URL the draft did not have) or a count mismatch between `verify.json` and call 2's completion report |
| `WARN: Line <track> pre-verify copy failed — …` / `WARN: Line <track> verify-diff could not run (non-fatal)` | The before-copy could not be written or compared; call 2's result is kept, its edits are not diffed |
| `WARN: clarity pass failed ...` | Call 2 (verification + clarity) failed (fail-open — the run still succeeds and the line is counted `unverified`) |
| `Audit pass: on (model <m>, effort high, ADR-0020)` | `[audit] enabled = true`; call 3 runs after call 2 for each article |
| `AUDIT <track>: {...}` | Call 3's tally for the line: `ran` (stage 1 returned a readable result), `reason` (why not: a call class such as `E_TRANSIENT`, `parse`, `E_BUDGET_GATE`, `note_unreadable`), claims checked / supported / unverifiable, `invalid` (malformed candidates dropped), `candidates`, `confirmed` (both stages call it a contradiction), `applied`, `rejected`, stage 2 calls, turns and cost. Summed into the metrics record's `verification` as `audit_*` |
| `WARN: Line <track> audit stage 1 did not run or failed (<class>) — …` | Stage 1 was not started (spend gate, unreadable or too long note) or failed. The note stays as call 2 left it; the run's result does not change |
| `WARN: Line <track> audit pass: 監査で確定した候補 D<n> を適用しなかった (<rule>) — …` | Both stages confirmed an error but the replacement broke a rule (`not_found` / `ambiguous` / `outside_body`: the sentence is not exactly once in the body; `empty`; `unchanged`; `short`: the sentence is under 15 characters; `newline`; `control`; `invisible`: adds a zero-width or bidi character; `edit_distance`: rewrites more than max(24, 30% of the sentence) characters; `markup`: adds `` ` `` `<` `>` `[[` `![` `%` `$=` or `&` to the note; `url_changed` / `link_changed` / `emphasis_changed` / `heading_changed`: the note's URLs, link targets, `**` / `` ` `` counts or heading lines change). The error is still in the note — fix it by hand from `runs/{date}.audit.json` |
| `WARN: Line <track> audit pass: 監査の置き換えをノートに書けなかった (<error>) — ノートは元のまま` | The replaced note could not be written; every applied candidate is recorded as `rejected` (`write_failed`) and the note is unchanged |
| `WARN: Line <track> audit stage 2 stopped — API spend cap …` / `WARN: Line <track> audit pass skipped …` | api mode: the day's remainder no longer covers the next audit call; or the audit did not start (after an auth / billing error) |
| `Line <track> audit pass skipped (kind: brief, only article is audited)` | Briefs are not audited |
| `WARN: report lint hard fail (ctl-016): ...` | Deterministic lint found a missing sources section / zero citations |
| `Completed successfully` | All of the day's picked lines completed and passed the report gate (including an all-quiet day) |

### Notifications

| Notification | Meaning |
|---------|------|
| `今朝のリサーチレポートが完成しました (今朝: … / 更新なし: … / 未検証: …)` | All lines succeeded and at least one report was published |
| `今朝は更新なし (更新なし: …)` | Every line ended quiet / hold (a success) |
| `リサーチが一部失敗しました (今朝: … / 更新なし: … / failed: …)。ログを確認してください。` | E_PARTIAL — the failed lines are named. When an auth / billing error (401 / 403 / 429 / credit) stops the run while picked lines are still unstarted and at least one line passed the gate, the day is E_PARTIAL even if no line failed the gate, and those lines are listed under 未実行. A day where no line passed the gate is E_NO_REPORT instead, and its notification `リサーチが失敗しました (lines:…)` lists only the failed lines. An error in the last picked line leaves nothing unstarted, so that day's notification follows the gate alone (a note whose call 2 failed is listed under 未検証) |

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

**Symptoms**: Log shows `ERROR: Another instance is running. Skipping.` or `ERROR: Could not verify the lock (…). Skipping.`

**Cause**: `Another instance` — the previous run is still active, or another `daily-research.sh` reuses the PID of a crashed run. `Could not verify the lock` — the check itself failed, and the run is skipped rather than risk running twice: the mutex `.daily-research.lock.mutex` was not free within 10 s (a stopped process holds it — find it with `lsof .daily-research.lock.mutex`), `python3` (which takes the mutex) failed or is not on the PATH, or the mutex file or lock directory could not be created (permissions, disk).

**Fix**:
```bash
# The lock is a DIRECTORY holding a pid file
cat .daily-research.lock/pid
ps aux | grep daily-research

# If no process is running, remove the stale lock directory
# (the script also steals, on its next start, a lock whose PID is dead, missing or empty, or now
#  belongs to a process other than daily-research.sh — e.g. a PID reused after a reboot.
#  Keep the neighbouring .daily-research.lock.mutex: it is the permanent file the lock is taken under)
rm -rf .daily-research.lock
```

### 4. A Line Consistently Failing

**Symptoms**: Log shows `WARN: Line <track> failed after retry` or `WARN: report gate failed for line <track> — ... (ctl-015)` on consecutive days.

**Causes**:
- Rate limit hit (the plan's quota in subscription mode; in api mode a 429 stops the run instead, see issue 5) or network issues during WebSearch
- The 25-minute per-line timeout expiring on an unusually deep run
- The line's `target_repo` path in `config.toml` missing or moved (a `mode = "ecosystem"` line has no `target_repo` — it runs from `state/<line>`, which the script creates, and logs `Line <track> mode: ecosystem (cwd = state/<track>)`)

**Fix**: Check the specific exit class in the log (`E_TRANSIENT` / `E_FATAL`). One line failing does not stop the others — their reports still land and get ingested; the day's final class is then `E_PARTIAL` (exit 1, `=== Failed (E_PARTIAL:<lines>, exit code 1) ===`), while `E_NO_REPORT` is reserved for a day where no line passed the gate (ADR-0011 / ADR-0017 — a day where every line ended quiet is a success, not `E_NO_REPORT`). Verify `target_repo` exists, then re-run the script manually. A 401 (`E_AUTH`) means the OAuth token expired (issue 1) or, in api mode, the key was rejected (issue 5).

### 5. API Mode: Rejected Key, Credit, Rate Limit or Spend Cap

**Symptoms**: `ERROR: Auth probe failed (api) — …`, `hit a billing/rate-limit error`, `API spend gate stopped the run`, or `API spend gate could not check the caps` in the log, with a macOS notification.

**Causes and fixes**:
- `status=401` / `403`: the key in `env_file` is wrong or revoked. Replace it there (never in the repo), then run `./scripts/check-auth.sh`.
- `Your credit balance is too low`: add credit on platform.claude.com.
- `status=429`: rate limit. The run stops on purpose instead of backing off (a burst of rate limits is a policy signal). Re-run later by hand.
- `API spend gate stopped the run`: the day's or month's remaining budget is below one line's reserve (`call1_max_usd + call2_max_usd`, plus `audit_max_usd + 5 × audit_confirm_max_usd` when `[audit] enabled`; the log's `Billing: api` line shows it as `line reserve`). Check `state/api-spend.jsonl`; raise the caps in `[billing]` only if the credit covers it.
- `API spend gate could not check the caps` right after `ERROR: API spend gate failed (rc …): …` or `ERROR: API spend ledger could not be written …`: the caps could not be checked, so the gate stopped before the next line: every remaining line stays unstarted (all of them when this happens before the first line), and lines that already finished keep their results. The rc 2 message names the first five unreadable ledger lines with their reasons, plus `and N more`; fix or remove those lines in `state/api-spend.jsonl` (or make the file writable again), then re-run.

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

**Symptoms**: A `claude -p` run burns much of its timeout on startup, or hangs indefinitely.

**Cause**: Claude Code plugins (pyright, swift-lsp, hookify, mgrep, claude-mem, etc.) installed globally. A `claude -p` invocation without `--safe-mode` initializes all plugin MCP servers, adding significant startup overhead. The unattended calls (call 1, call 2 and the auth probe) start with `--safe-mode`, which disables installed plugins and MCP servers, so this applies to `claude` runs you start by hand in this project — e.g. following a protocol interactively. A per-line run that still stalls at startup points elsewhere; `timeout -k` bounds every unattended call.

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

**Cause**: `past_topics.json` not updated properly (the run's question selection depends on the past questions and their `answer_scope` it feeds). The script appends each line's question from its receipt after the gate passes (`past-topics-append`); a failure logs `WARN: Line <track> past_topics.json append failed`. `state/<line>/brief.md` is a static document you write; if the line keeps returning to one subject, narrow or reword its subject there.

**Fix**:
```bash
# Check past_topics.json
cat past_topics.json | python3 -m json.tool

# Restore from backup if corrupted
cp past_topics.json.bak past_topics.json
```

### 9. Audit (Call 3) Changed a Note, or Left an Error In

**Symptoms**: a note reads differently from what call 2 left, or `audit pass: 監査で確定した候補 … を適用しなかった` / `audit stage 1 did not run or failed` in the log.

**Where to look**: `state/<line>/runs/{date}.audit.json` holds every candidate with its status (`applied`, `rejected` + rule, `not_confirmed` + stage 2's verdict, `confirm_failed`, `skipped` + `drift` / `duplicate` / `over_cap`), the source quote and the URL each stage read. `state/<line>/pre-audit/{date}.md` is the note before the audit.

**Fixes**:
```bash
# What the audit changed
diff state/<line>/pre-audit/<date>.md "<vault_path>/daily-research/<date>_<line>_<slug>.md"

# Undo the audit for one note (the pre-audit copy is the note after call 2)
cp state/<line>/pre-audit/<date>.md "<vault_path>/daily-research/<date>_<line>_<slug>.md"

# Turn the audit off: in config.toml
#   [audit]
#   enabled = false
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

Each morning the `lines_per_day` lines of the rotation window plus every `daily = true` line run (ADR-0010 / ADR-0011 / ADR-0017 / ADR-0019). Per line: Call 1 = one Opus research run (at most 2 invocations with its single retry) plus Call 2 = one verification + clarity pass (`[verification] model`); a line that ends quiet or hold skips Call 2. With `[audit] enabled`, an article adds Call 3 = one audit run plus one confirmation run per candidate, at most 5 (`[audit] model`). Timeouts and turn limits are in `scripts/daily-research.sh`.

**Who pays** is `[billing] mode` in `config.toml` (`scripts/lib/billing.sh`; the contract is `[billing]` in `scripts/lib/dr_pipeline.py`):

| mode | Auth | Billing | Limits |
|---|---|---|---|
| `subscription` (default) | Claude Code login (OAuth) | No per-token charge on a Max plan; counts against the plan's usage limits | The plan's own limits. Any `ANTHROPIC_API_KEY` in the environment is dropped |
| `api` | `ANTHROPIC_API_KEY` read from `env_file`, a file outside the repo that the model is denied from reading | Every call is billed to the Claude API | `--max-budget-usd` per call (`call1_max_usd`, `call2_max_usd`, `audit_max_usd`, `audit_confirm_max_usd`); a line starts only if the day's and the month's remaining budget both cover call1 + call2 (+ the audit's reserve when `[audit] enabled`) (`daily_cap_usd`, `monthly_cap_usd`). Otherwise the remaining lines are skipped with a notification; a day where no line started ends as `E_BUDGET` (exit 1) |

In `api` mode every call's cost (the `total_cost_usd` Claude Code reports, including the auth probe) is appended to `state/api-spend.jsonl`; the caps read that file, and the day's and month's totals are logged as `API spend: today … month …`. A 429, a too-low credit balance or a rejected key stops the remaining lines without a retry (`E_BILLING` / `E_AUTH`).

**Actual spend.** `./scripts/check-auth.sh` prints the month's spend so far, and `state/api-spend.jsonl` has one line per call. The defaults for the caps are in `config.example.toml`; set yours from what the ledger shows.
