# Daily Research

A Japanese morning edition for discovering what you might want to think about or try next.
One lead story and a few short discoveries connect unfamiliar examples, research and questions to a curious reader. Immediate usefulness to a project is optional.

[日本語](README.ja.md)

## How it works

Claude Opus explores the web with a short reader profile. A separate Opus session receives its evidence packet and the last 30 days of delivered titles, selects the edition, and can investigate further. It may publish only briefs or record a quiet day when the material is weak.

Both sessions run in an isolated working directory with `--safe-mode` and only WebSearch/WebFetch tools. Models return structured JSON; Python validates and saves it. Exploration does not load project repositories or accumulated playbooks. Human feedback can update the reader profile deliberately.

Normal editions and briefs go to your Obsidian vault as `YYYY-MM-DD_discovery_edition.md`. Quiet notices stay private. The existing wiki ingest runs for a newly published current-day edition. The included launchd job runs at 05:00.

## Setup

Requires Bash, Python 3.11+, GNU `timeout` (Homebrew coreutils), and an authenticated Claude Code CLI supporting `--safe-mode` and structured JSON output. Claude subscription authentication remains in use.

```bash
cp config.example.toml config.toml
cp reader-profile.example.md reader-profile.md
# Edit config.toml with your vault path, then personalize reader-profile.md.
./scripts/daily-research.sh --preview
```

Preview output stays in the repository's private working area; it does not update the vault, production history or wiki. Run without `--preview` to publish. `--date YYYY-MM-DD` selects the edition date; `--config PATH` selects a different configuration. Dates other than today require `--preview`; a historical date does not recreate the historical web.

See [operations](docs/RUNBOOK.md) for scheduling and recovery, [development](docs/CONTRIB.md) for tests, and [ADR-0016](docs/adr/0016-discovery-first-edition.md) for the decision.

## What counts as improvement

After a week, read the editions and ask which made you want to follow a story, which started a new thought, and which felt repetitive. Inspect the saved candidates to distinguish a search failure from an editorial choice. Article count and source count are not measures of interest.

The source graph and old research state are historical archives. This design is an experiment in the reading experience, not an established improvement in quality.
