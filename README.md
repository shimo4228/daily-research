Language: English | [日本語](README.ja.md)

# daily-research

**A research feedback engine for your own research repositories.** Every morning, [Claude Code](https://docs.anthropic.com/en/docs/claude-code) reads the concept graph of each repo you maintain and researches the latest external work that *develops* it — filling coverage gaps while they exist, then switching to research that challenges or extends the concepts once coverage saturates — plus one free-exploration line that hunts serendipity outside your saturated territory. Reports land in your [Obsidian](https://obsidian.md) vault, each ending with a contribution section you fold back in by hand.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE) [![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/shimo4228/daily-research) [![GitMCP](https://img.shields.io/endpoint?url=https://gitmcp.io/badge/shimo4228/daily-research)](https://gitmcp.io/shimo4228/daily-research) ![python](https://img.shields.io/badge/python-3.11%2B%20stdlib-3776ab.svg)

It runs unattended via macOS `launchd`, with no API plumbing and no orchestration framework: a shell script drives Claude Code's non-interactive mode (`claude -p`), and a small stdlib-only Python module parses JSON/TOML. The intelligence lives in the prompts.

> **Who it's for:** anyone maintaining one or more research repositories with a `graph.jsonld` concept graph who wants a daily, self-directed stream of external research aimed at the repo's actual frontier — not generic trends.

## How it works

```mermaid
flowchart TD
    cron["launchd — 05:00 daily"] --> orch["daily-research.sh"]
    orch --> prep["auth probe · sync repo graphs → .repo-graphs/<br/>coverage-report (per-repo mode) · cluster-report"]
    prep --> p1["Pass 1 · Opus<br/>theme selection — one theme per line<br/>coverage / frontier / explore"]
    p1 -->|themes JSON| p2["Pass 2 · Sonnet<br/>10–20 web searches · fetch sources<br/>write reports · update graph.jsonld"]
    p1 -.->|Pass 1 fails| p2
    p2 --> out[("Obsidian vault — reports<br/>+ graph.jsonld history")]
```

The pipeline runs two Claude Code passes: **Opus** selects themes (deep reasoning over the repo graphs), then **Sonnet** does the search-heavy research and writing. If Pass 1 fails, Sonnet handles theme selection too. Each **line** maps to zero or more research repos, and each repo carries a deterministic selection mode judged by `coverage-report`:

- **coverage** — the repo still has uncovered / thinly-reinforced concepts: pick research that closes those gaps. "Every concept in the repo's graph minus the concepts already reinforced in `graph.jsonld`" is a concrete, repeatable target.
- **frontier** — coverage has saturated: stop gap-filling and pick research that *challenges* or *extends* the repo's concepts, steered by standing `frontier_questions` you write in the config ([ADR-0004](docs/adr/0004-line-restructuring-and-frontier-mode.md)).
- **explore** — a line with no repos: free exploration for serendipity, mechanically repelled from the saturated clusters `cluster-report` computes over the whole graph history.

This started as a generic trend-research tool. Fixed topic domains caused structural saturation (one concept cluster grew to 37% of all topics), so on 2026-05-27 each track was remapped to one research repository ([ADR-0001](docs/adr/0001-research-repo-feedback-engine.md)); when the coverage engine ran its gaps dry, tracks were consolidated into lines with frontier mode and the free-exploration line was reintroduced with cluster repulsion ([ADR-0004](docs/adr/0004-line-restructuring-and-frontier-mode.md)).

## Core concepts

- **Coverage gap** — a concept present in a repo's graph but not yet recorded under `reinforces` in `graph.jsonld`. While gaps exist they are the primary targets of theme selection, and they shrink as Pass 2 records each reinforced concept.
- **Frontier mode** — the post-saturation objective: once a repo has no gaps left, themes must challenge (`challenges`) or extend (`extends`) existing concepts, or propose new-concept candidates, guided by per-repo `frontier_questions`. Thickness statistics count only `reinforces`; dedup counts the union.
- **Cluster repulsion** — the free-exploration line's novelty guard: high-frequency subClusters (all-time top-N ∪ recently hot) are off-limits, mechanically preventing the saturation that killed the original trend tracks.
- **Frontier-diff reporting** — a report is the *delta* against a repo's current concept frontier, not a digest of accumulated content. This is the output-side dual of the same signal-first filter that drives theme selection ([ADR-0002](docs/adr/0002-reports-as-frontier-diff.md)).
- **Concept cluster graph** — `graph.jsonld`, a schema.org JSON-LD persistent memory whose report nodes are grouped into 7 broad concept clusters; Pass 2 updates it incrementally each run. Schema in [graph-schema.md](docs/graph-schema.md).
- **Repo feedback loop** — repos are referenced **read-only**; the pipeline never edits them. Contributions flow through vault reports that a human folds back in, avoiding cross-repo pollution.

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | `brew install claude` or via npm |
| [Claude Max plan](https://claude.ai) | For zero-cost non-interactive usage |
| `python3` >= 3.11 | Stdlib only (`json` / `tomllib` / `re`) for JSON/TOML parsing. macOS system 3.9 lacks `tomllib`; use Homebrew's `python3` |
| macOS | Uses `launchd` for scheduling (Linux: adapt to `cron` / `systemd`) |
| Obsidian (optional) | Any markdown tool works |
| Research repositories | One or more repos carrying a `graph.jsonld` concept graph ([schema](docs/graph-schema.md)) |

## Quick start

```bash
# 1. Clone
git clone https://github.com/shimo4228/daily-research.git daily-research
cd daily-research

# 2. Configure — set vault_path and define lines (repo-backed and/or free-exploration)
cp config.example.toml config.toml

# 3. Make scripts executable
chmod +x scripts/*.sh

# 4. Verify Claude auth (real OAuth probe)
./scripts/check-auth.sh

# 5. (Optional) Bootstrap the concept graph from existing topic history
./scripts/bootstrap-graph.sh

# 6. Test run — in a SEPARATE terminal, never inside a Claude Code session
./scripts/daily-research.sh

# 7. Schedule with launchd (optional)
cp com.example.daily-research.plist com.daily-research.plist   # edit YOUR_USERNAME
ln -sf "$(pwd)/com.daily-research.plist" ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.daily-research.plist
```

**Install as a Claude Code skill:** the repo ships a [`SKILL.md`](SKILL.md) manifest at root, so cloning it into `~/.claude/skills/daily-research` makes it invocable as `/daily-research`.

## Configure a line

Each `[tracks.X]` entry is a research **line**. A line maps to 0..N research repositories via `[[tracks.X.repos]]`; a line with no repos is a free-exploration line. There are no fixed `domains` — the area of interest is derived from the repo graphs (and the saturation statistics) at runtime.

```toml
[tracks.line_a]
name = "Research Line A (repo_a + repo_b)"
focus = "External research that reinforces, challenges, or extends repo A and repo B"
aliases = ["old_track_a1", "old_track_a2"]      # legacy track names whose history keeps feeding dedup
sources = ["Semantic Scholar (your repos' keywords)", "arXiv (relevant categories)"]
scoring_criteria = [
  { name = "Concept reinforcement / frontier fit", weight = 35, desc = "Closes a gap, or challenges/extends a concept" },
  { name = "Research recency",                     weight = 25, desc = "Latest research or development" },
  { name = "Repo frontier fit",                    weight = 40, desc = "Serves the repos' next direction" },
]

[[tracks.line_a.repos]]
key = "repo_a"                                   # used for .repo-graphs/<key>.jsonld and theme routing
target_repo = "/path/to/your/research-repo-a"
target_graph = ".repo-graphs/repo_a.jsonld"
target_doi = "10.xxxx/zenodo.xxxxxxxx"           # optional
frontier_questions = [
  "A standing open question that drives theme selection once coverage saturates",
]

[tracks.explore]
name = "Free Exploration"                        # no repos → explore mode with cluster repulsion
sources = ["Hacker News top stories", "GitHub Trending", "arXiv cs.* new papers"]
scoring_criteria = [
  { name = "Novelty",      weight = 30, desc = "No similar theme in past topics" },
  { name = "Serendipity",  weight = 30, desc = "Distant from saturated clusters" },
  { name = "Momentum",     weight = 20, desc = "Actively evolving area" },
  { name = "Whisper trend", weight = 20, desc = "Not yet widely noticed" },
]

[coverage]
frontier_threshold = 0      # repo enters frontier mode when uncovered+thin <= this
saturated_top_n = 15        # cluster repulsion: all-time top-N subClusters are off-limits
saturated_recent_days = 90
saturated_recent_min = 3
```

Reports are generated in Japanese by default; change the language constraint in `prompts/research-protocol.md`. See [CONTRIB](docs/CONTRIB.md) for tuning research depth, CLI flags, and environment variables.

## Project structure

```
daily-research/
├── scripts/
│   ├── daily-research.sh       # Orchestrator (sources lib/, preflight → Pass 1/2)
│   ├── lib/                    # Sourced shell libraries + the Python parsing module
│   │   ├── env.sh log.sh notify.sh lock.sh graph.sh auth.sh claude.sh
│   │   └── dr_pipeline.py      # Single stdlib-only JSON/TOML parsing module
│   ├── coverage-report.sh      # Coverage + per-repo mode report (thin wrapper over dr_pipeline.py), injected into Pass 1
│   ├── bootstrap-graph.sh      # One-shot graph.jsonld bootstrap (Opus clustering)
│   ├── check-auth.sh           # Real OAuth probe health check (shares lib/auth.sh)
│   └── pre-commit.sh           # Secret / syntax guard
├── prompts/                    # Pass 1 theme selection, Pass 2 task + research protocol
├── templates/report-template.md
├── graph.jsonld                # Persistent memory: concept clusters + repo engagement history
├── config.example.toml         # Line → repos mapping (config.toml is gitignored)
├── tests/                      # bats (daily-research / e2e-mock / lib) + pytest (dr_pipeline_test.py)
└── docs/                       # RUNBOOK, CONTRIB, graph-schema, adr/
```

## Key design decisions

| Decision | Why |
|----------|-----|
| Lines map to repo graphs (coverage-gap driven while gaps exist) | Fixed topic domains caused structural saturation; mapping to a repo graph prevents domain narrowing ([ADR-0001](docs/adr/0001-research-repo-feedback-engine.md)) |
| Frontier mode + free-exploration line with cluster repulsion | A gap-driven engine completes by design; saturation flips the objective to challenge/extend, and serendipity gets its own mechanically-guarded line ([ADR-0004](docs/adr/0004-line-restructuring-and-frontier-mode.md)) |
| Reports as frontier-diff | A report is the delta against a repo's evolving concept graph, not a digest ([ADR-0002](docs/adr/0002-reports-as-frontier-diff.md)) |
| Local JSON-LD graph, not external MCP memory | The previous Mem0 MCP integration ran zero times for 32 days due to silent failure; a local file fails loudly |
| 2-pass (Opus + Sonnet) | Opus is stronger at theme selection; Sonnet is faster and cheaper for research and writing |
| Read-only repo reference | Contributions flow through vault reports a human folds back in, avoiding cross-repo pollution |
| Shell orchestration + stdlib Python parser | No pip dependencies at runtime; JSON/TOML parsing lives in one testable `dr_pipeline.py` module |

Operational rationale (real auth probe vs `--version`, `--append-system-prompt-file`, `--allowedTools`, `--max-turns`, `< /dev/null` stdin redirect) lives in [CONTRIB](docs/CONTRIB.md). In the author's own use, daily-research is also the *write* side of a knowledge cycle shared across several research lines — observed architecture, not a roadmap ([ADR-0003](docs/adr/0003-cross-line-knowledge-cycle.md)).

## Gotchas

- **Run in a separate terminal** — `claude -p` cannot be nested inside another Claude Code session.
- **OAuth token expires ~4 days** — refresh by running `claude` interactively. The real auth probe fails loudly with a re-auth notification instead of silently double-failing.
- **`ANTHROPIC_API_KEY` must be unset** — if set, Claude uses per-token billing instead of the Max plan. The script handles this with `unset`.
- **Claude Code plugins cause hangs** — globally-installed plugins initialize their MCP servers on every `claude -p` call. Disable them per-project in `.claude/settings.json` (see [RUNBOOK](docs/RUNBOOK.md)).
- **launchd doesn't source `.zshrc`** — all PATH entries must be explicit in the script and plist.

## Docs

- [RUNBOOK](docs/RUNBOOK.md) / [日本語](docs/RUNBOOK.ja.md) — operations: monitoring, troubleshooting
- [CONTRIB](docs/CONTRIB.md) / [日本語](docs/CONTRIB.ja.md) — development: testing, CLI flags, environment variables
- [graph-schema.md](docs/graph-schema.md) — `graph.jsonld` schema: node types, cluster naming, integrity rules
- [ADR-0001](docs/adr/0001-research-repo-feedback-engine.md) · [ADR-0002](docs/adr/0002-reports-as-frontier-diff.md) · [ADR-0003](docs/adr/0003-cross-line-knowledge-cycle.md) · [ADR-0004](docs/adr/0004-line-restructuring-and-frontier-mode.md) — architecture decisions

## License

[MIT](LICENSE)
