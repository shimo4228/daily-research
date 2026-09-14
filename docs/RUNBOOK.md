# Operations

## Run and inspect

```bash
./scripts/check-auth.sh
./scripts/daily-research.sh --preview
./scripts/daily-research.sh --preview --date 2026-09-06
./scripts/daily-research.sh
```

`--config PATH` selects an alternative TOML file; reader profile paths are relative to the repository root. Defaults are in `config.example.toml`. Preview has separate logs/state and does not touch production history, Vault notes or wiki ingestion. The research packet and editorial result remain available for inspection in private run artifacts.

Normal editions and briefs are validated before saving to `<vault_path>/<output_dir>/YYYY-MM-DD_discovery_edition.md`. A same-date rerun does not duplicate a saved edition or its wiki handoff. Quiet output remains private and is announced locally; it is not a report to ingest. Dates other than today require `--preview`.

## Schedule

Production artifacts live in `state/discovery/runs/`; previews live in `.notes/discovery-runs/`. Logs live in `logs/YYYY-MM-DD.log` or `.notes/discovery-preview-logs/YYYY-MM-DD.log`. Each run archives inputs, protocols, JSON schemas, CLI responses, the edition, result and metrics.

Retain the existing launchd job pointing at the absolute path to `scripts/daily-research.sh`; its configured time is 05:00. Ensure the scheduler's PATH contains Claude, Python 3.11+ and GNU `timeout` (Homebrew coreutils). The wrapper uses a lock to prevent concurrent runs. Do not launch another job as a workaround for an active lock without checking the running process.

## Failure and recovery

Authentication failure, unsupported CLI flags, invalid structured output and timeout are execution failures, not quiet days. Check the current run log and stage outputs before changing prompts. Timeout exhausts the stage budget and is not retried. Other temporary execution errors may retry once; weak material does not trigger another run. No incomplete editorial output should be published.

Check `claude --help` for `--safe-mode` and structured-output support if startup fails, and authenticate interactively if necessary. Do not fall back to an unisolated run. If wiki ingest fails after publication, retain the note and inspect ingest logs rather than regenerating the article.

## Review and rollback

After seven days, read the editions with the user and compare them with the pre-change baseline. Ask what they wanted to follow, what started a thought, and what felt repetitive. Use the saved candidate packet to distinguish discovery from selection problems. Update the reader profile only after the user accepts a change.

The old configuration is backed up during local migration; prior code and tracked prompts remain in Git history. To return to the previous runtime, restore code and matching configuration together. Do not roll back article archives or rewrite past editions. Keep `graph.jsonld` frozen. Do not include private profiles, logs or packets in public commits.
