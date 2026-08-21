---
name: daily-research
description: Automated daily per-repo research — cron-driven pipeline that runs claude -p inside each mapped research repo, explains one external development relevant to the repo and what it means for it, and writes free-form explanatory research notes to an Obsidian vault. Bash orchestration with prompts over claude -p; JSON/TOML parsing in stdlib python3 (no pip dependencies).
compatibility: Requires the Claude Code CLI (claude -p), a cron/launchd scheduler, and python3 >=3.11 (stdlib only). Bash + prompts + stdlib python3.
user-invocable: true
origin: shimo4228
---

# daily-research

Autonomous daily research powered by `claude -p` (Claude Code's non-interactive mode) — each morning one rotation-picked research line (plus every `daily = true` line) runs call 1 (Opus research) *inside* the line's repo (cwd = the repo) so it reads the repo's own operational context, picks one external development relevant to the repo, explains what happened, why it matters, and how the repo can use it, and writes a free-form explanatory note; call 2 (Sonnet, fresh context, fail-open) then revises the note for first-contact readability (ADR-0010 / ADR-0014). Notes go — readable with zero prior context — directly to an Obsidian vault. Deadline-bound opportunities are captured in a fixed 機会メモ tail section; notes carry no proposals or approval requests (ADR-0009).

**Skill anatomy**: `prompts/repo-research-protocol.md` is the skill's core intelligence. `prompts/clarity-review-protocol.md` drives call 2. `scripts/daily-research.sh` is a thin wrapper that picks the day's lines and invokes `claude -p` twice per line with those protocols. Everything else (tests, launchd plists, config template) is supporting infrastructure.

## When to use

- **Scheduled daily execution** — macOS `launchd` (included) or any cron / systemd setup
- **Manual one-shot run** — `./scripts/daily-research.sh` or invoke via `/daily-research` after installing as a Claude Code skill

## Design philosophy

One development, explained. A run generates 2–3 candidate themes and keeps one by three yes/no questions — is it new, can a primary source be reached in-run, can its use in the repo be named concretely — then explains it for a reader with zero prior context, keeping fact and interpretation apart (ADR-0014). The pipeline's capacity is defined by human attention, not by source count — hence one rotated line per morning — and the upstream filter (diff-first over watched sources, theme screen, citation gate), not downstream storage, is where quality is enforced. Every claim carries an as-of date and every deadline-bound opportunity an expiry date: knowledge here goes stale on a one-week scale.

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
