---
name: daily-research
description: Automated daily signal-first research digest — cron-driven pipeline that selects themes, researches with web tools, and writes reports to an Obsidian vault. Zero Python, just prompts and a shell wrapper over claude -p.
compatibility: Requires the Claude Code CLI (claude -p) and a cron/launchd scheduler. Shell + prompts, no Python.
user-invocable: true
origin: original
---

# daily-research

Autonomous daily research powered by `claude -p` (Claude Code's non-interactive mode) — theme selection with Opus, multi-stage web research with Sonnet, LLM-as-Judge quality evaluation, reports written directly to an Obsidian vault.

**Skill anatomy**: `prompts/` are the skill's core intelligence. `scripts/daily-research.sh` is a thin wrapper that invokes `claude -p` with those prompts. Everything else (tests, launchd plist, config template) is supporting infrastructure.

## When to use

- **Scheduled daily execution** — macOS `launchd` (included) or any cron / systemd setup
- **Manual one-shot run** — `./scripts/daily-research.sh` or invoke via `/daily-research` after installing as a Claude Code skill

## Design philosophy

Signal-first intake. The theme selector admits topics only if they would meaningfully change what the reader acts on the next day; lower-signal candidates are dropped at the filter rather than stored and digested later. The pipeline's capacity is defined by human attention, not by source count — so the upstream filter, not the downstream storage, is where quality is enforced.

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
