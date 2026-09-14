---
name: daily-research
description: Run a Japanese morning discovery edition using two isolated Claude sessions. Use for scheduled research, a manual daily edition, or a private preview. Not for repository implementation or general one-off research discussion.
compatibility: Bash, Python >=3.11, GNU timeout and authenticated Claude Code CLI with safe-mode and structured output.
user-invocable: true
origin: shimo4228
---

# Daily Research

Run `./scripts/daily-research.sh --preview` for a private trial or
`./scripts/daily-research.sh` for the configured Vault edition.
Configuration and setup: [README](README.md). Operations: [RUNBOOK](docs/RUNBOOK.md).

Exploration and editorial judgment have separate contexts. The reader profile is a starting point
for discovery; the editorial session may investigate further and select a normal edition, briefs,
or quiet notice. The executable schema and validation live in `scripts/lib/discovery.py`.
The narrative instructions live in the two `prompts/` protocols.

A run is not authorization to implement an idea found in an article, update reader preferences,
or alter research repositories. The wrapper owns persistence and wiki handoff.
