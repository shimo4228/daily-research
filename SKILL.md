---
name: daily-research
description: Automated daily per-repo research — cron-driven pipeline that runs claude -p inside each mapped research repo, hunts for immediately executable moves, and writes actionable-tactics notes to an Obsidian vault. Bash orchestration with prompts over claude -p; JSON/TOML parsing in stdlib python3 (no pip dependencies).
compatibility: Requires the Claude Code CLI (claude -p), a cron/launchd scheduler, and python3 >=3.11 (stdlib only). Bash + prompts + stdlib python3.
user-invocable: true
origin: shimo4228
---

# daily-research

Autonomous daily research powered by `claude -p` (Claude Code's non-interactive mode) — one Sonnet run per research line, executed *inside* the line's repo (cwd = the repo) so it reads the repo's own operational context, hunting for immediately executable moves and writing actionable-tactics notes directly to an Obsidian vault. A deterministic 07:00 morning brief forwards the proposed moves to Slack for approval.

**Skill anatomy**: `prompts/repo-research-protocol.md` is the skill's core intelligence. `scripts/daily-research.sh` is a thin wrapper that invokes `claude -p` per line with that protocol; `scripts/morning-brief.sh` is the no-LLM approval brief. Everything else (tests, launchd plists, config template) is supporting infrastructure.

## When to use

- **Scheduled daily execution** — macOS `launchd` (included) or any cron / systemd setup
- **Manual one-shot run** — `./scripts/daily-research.sh` or invoke via `/daily-research` after installing as a Claude Code skill

## Design philosophy

Action-first intake. A run admits a finding only if it becomes an immediately executable move — or a refutation that changes the line's next action; corroboration is never a theme, and "nothing actionable today" with evidence is a valid output. The pipeline's capacity is defined by human attention, not by source count — so the upstream filter (diff-first over watched sources, premise-challenge pass, citation gate), not downstream storage, is where quality is enforced. Every claim carries an as-of date and every move an expiry condition: knowledge here goes stale on a one-week scale.

## Execution

```bash
./scripts/daily-research.sh
```

Prerequisites, configuration, and scheduling are documented in the main [README](README.md#prerequisites). Operations details (monitoring, troubleshooting) are in [RUNBOOK](docs/RUNBOOK.md).

## Install as a Claude Code skill

```bash
git clone https://github.com/shimo4228/daily-research.git \
  ~/.claude/skills/daily-research
```

After cloning, Claude Code recognizes `SKILL.md` and the skill becomes invocable as `/daily-research`. For automatic daily execution, follow the launchd or cron setup in the main README.

## Documentation

- [README.md](README.md) / [README.ja.md](README.ja.md) — overview, features, quick start, design decisions
- [docs/RUNBOOK.md](docs/RUNBOOK.md) / [docs/RUNBOOK.ja.md](docs/RUNBOOK.ja.md) — operations guide
- [docs/CONTRIB.md](docs/CONTRIB.md) / [docs/CONTRIB.ja.md](docs/CONTRIB.ja.md) — development guide
- [config.example.toml](config.example.toml) — configuration template
