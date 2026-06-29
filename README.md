Language: English | [日本語](README.ja.md)

# daily-research

A research feedback engine for your own research repositories, powered by [Claude Code](https://docs.anthropic.com/en/docs/claude-code) non-interactive mode and macOS `launchd`.

**Shell orchestration + a stdlib-only Python parsing layer. No pip dependencies at runtime.**

Every morning at 5:00 AM, Claude reads the concept graph of each research repository you maintain, finds the concepts that external research has not reinforced yet, researches the latest work that fills those gaps, and writes reports into your [Obsidian](https://obsidian.md) vault. The reports end with a "contribution to this repo" section so you can fold the findings back into the source repository by hand.

This started as a generic trend-research tool (tech / personal / ai_dev tracks). On 2026-05-27 it was reworked: fixed topic domains caused structural saturation (one concept cluster grew to 37% of all topics), so each track is now mapped to one research repository and themes are driven by that repo's concept coverage gaps. See [ADR-0001](docs/adr/0001-research-repo-feedback-engine.md) for the full rationale.

## How It Works

```
launchd (AM 5:00)
  └─ daily-research.sh
       ├── Auth check (check-auth.sh)
       ├── Sync each repo's graph → .repo-graphs/<track>.jsonld
       ├── coverage-report.sh        # uncovered concepts per track
       │
       ├── Pass 1: Opus (theme selection)
       │     ├── Read config.toml          # track → repo mapping
       │     ├── Read repo graphs + coverage report
       │     ├── WebSearch                 # research reinforcing uncovered concepts
       │     └── Score & select one theme per track
       │
       ├── Pass 2: Sonnet (research & writing)
       │     ├── WebSearch x 10-20         # multi-stage research
       │     ├── WebFetch (primary sources)
       │     ├── Write reports             # → Obsidian vault
       │     ├── Append "contribution to this repo" section
       │     ├── Update past_topics.json   # topic history
       │     └── Update graph.jsonld       # record reinforced concepts
```

**2-pass architecture**: Opus handles theme selection (deep reasoning over the repo graphs), Sonnet handles research and writing (faster, cheaper). If Pass 1 fails, Sonnet handles everything as a fallback.

**Concept coverage drives the search.** Instead of chasing trends, the pipeline computes "every concept `@id` in a repo's graph minus the concepts already reinforced in `graph.jsonld`" and asks Pass 1 to prioritize external research that closes those gaps. Trends come and go; an uncovered concept is a concrete, repeatable target.

The key insight: Claude Code's `-p` flag turns it into a fully autonomous research agent. No API plumbing, no orchestration framework — a shell orchestrator drives the passes, and a small stdlib-only Python module (`scripts/lib/dr_pipeline.py`) handles JSON/TOML parsing. The intelligence lives in the prompt.

## Features

- **2-pass model routing** -- Opus for theme selection, Sonnet for research and writing
- **Repo-mapped research tracks** -- each track maps to one research repository; the area of interest is derived from that repo's `graph.jsonld`, not from fixed keyword domains
- **Coverage-driven theme selection** -- `coverage-report.sh` lists the uncovered / thinly-supported concepts per repo and injects them into Pass 1
- **Concept cluster graph** -- `graph.jsonld`, a schema.org JSON-LD persistent memory (310 articles across 7 broad and 82 sub clusters); Pass 2 updates it incrementally each run
- **Topic history** -- `past_topics.json` accumulates a chronological log of selected themes (Pass 2 updates it; Pass 1's de-duplication role moved to `coverage-report.sh`)
- **Multi-stage deep research** -- not just a summary; generates research questions, searches 10-20 times, cross-validates sources
- **Repo feedback loop** -- each report ends with a "contribution to this repo" section naming the reinforced concepts and suggesting how to extend the repo
- **Obsidian-native output** -- reports with YAML frontmatter, ready for your vault
- **Operational safety nets** -- lock files, log rotation, auth checks, macOS notifications, automatic Sonnet fallback

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | `brew install claude` or via npm |
| [Claude Max plan](https://claude.ai) | For zero-cost non-interactive usage |
| `python3` >= 3.11 | Stdlib only (`json` / `tomllib` / `re`) for the JSON/TOML parsing layer. macOS system 3.9 lacks `tomllib`; use Homebrew's `python3` |
| macOS | Uses `launchd` for scheduling (Linux users: adapt to `cron` or `systemd`) |
| Obsidian (optional) | Any markdown-compatible tool works |
| Research repositories | One or more repos that carry a `graph.jsonld` concept graph (see [graph-schema.md](docs/graph-schema.md)) |

## Install as a Claude Code skill

```bash
git clone https://github.com/shimo4228/daily-research.git \
  ~/.claude/skills/daily-research
```

The repo ships a [`SKILL.md`](SKILL.md) manifest at root, so Claude Code recognizes it as a skill. After cloning you can invoke it manually as `/daily-research`, or set up scheduled execution — see "Quick Start" below for launchd (macOS). For Linux, swap the launchd step for cron or systemd.

## Quick Start

```bash
# 1. Clone
git clone https://github.com/shimo4228/daily-research.git daily-research
cd daily-research

# 2. Configure
cp config.example.toml config.toml
# Edit config.toml: set vault_path and map each track to a research repo

# 3. Make scripts executable
chmod +x scripts/daily-research.sh scripts/coverage-report.sh \
         scripts/check-auth.sh scripts/bootstrap-graph.sh

# 4. Verify Claude auth
./scripts/check-auth.sh

# 5. (Optional) Bootstrap the concept graph from existing topic history
#    Run once if you have a past_topics.json to classify into clusters.
./scripts/bootstrap-graph.sh

# 6. Test run (manual; use a separate terminal, not inside a Claude Code session)
./scripts/daily-research.sh

# 7. Schedule with launchd (optional)
cp com.example.daily-research.plist com.daily-research.plist
# Edit: replace YOUR_USERNAME with your macOS username
ln -sf "$(pwd)/com.daily-research.plist" ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.daily-research.plist
```

## Project Structure

```
daily-research/
├── scripts/
│   ├── daily-research.sh       # Orchestrator (sources lib/, preflight → Pass 1/2/3)
│   ├── lib/                    # Sourced shell libraries + the Python parsing module
│   │   ├── env.sh              # Env sanitize + PATH
│   │   ├── log.sh              # log() / log_init() (chmod at creation, rotation)
│   │   ├── notify.sh           # notify() (osascript guard)
│   │   ├── lock.sh             # acquire_lock()/release_lock() (mkdir-atomic)
│   │   ├── graph.sh            # check_graph_health()/sync_repo_graphs()
│   │   ├── auth.sh             # real_auth_probe() (real OAuth probe, shared by 3 entrypoints)
│   │   ├── claude.sh           # run_claude()/classify_exit() (E_AUTH/E_TRANSIENT/E_FATAL)
│   │   └── dr_pipeline.py      # Single stdlib-only JSON/TOML parsing module (subcommands)
│   ├── bootstrap-graph.sh      # One-shot graph.jsonld bootstrap (Opus clustering)
│   ├── coverage-report.sh      # Uncovered-concept report, injected into Pass 1
│   └── check-auth.sh           # Real OAuth probe health check (shares lib/auth.sh)
├── prompts/
│   ├── theme-selection-prompt.md  # Pass 1: repo-graph-driven theme selection (Opus)
│   ├── task-prompt.md             # Pass 2: research & writing instruction (Sonnet)
│   └── research-protocol.md       # Pass 2: research protocol (quality core, system prompt)
├── templates/
│   └── report-template.md      # Report format with YAML frontmatter
├── graph.jsonld                # Persistent memory: concept cluster graph + reinforcement history (tracked)
├── .repo-graphs/               # Per-track synced repo graphs (generated at startup, gitignored)
├── config.example.toml         # Track → repo mapping, scoring, output (config.toml is gitignored)
├── past_topics.example.json    # Topic history schema reference
├── tests/                      # bats (daily-research / e2e-mock / lib) + pytest (dr_pipeline_test.py) + fixtures/
├── docs/
│   ├── RUNBOOK.md / RUNBOOK.ja.md   # Operations guide
│   ├── CONTRIB.md / CONTRIB.ja.md   # Development guide
│   ├── graph-schema.md              # graph.jsonld schema spec
│   ├── adr/                         # Architecture Decision Records
│   └── progress/                    # Postmortems and evaluation reports
└── com.example.daily-research.plist  # launchd schedule template
```

## Concept Coverage Engine

Each track points at one research repository. At startup the repo's `graph.jsonld` is copied into `.repo-graphs/<track>.jsonld` (read-only; the source repo is never edited). `coverage-report.sh` then diffs two sets:

- every concept `@id` declared in the repo's graph, and
- every concept already recorded under `reinforces` in this project's `graph.jsonld`.

The difference is the set of **uncovered concepts**. Pass 1 receives this report and selects external research that reinforces those concepts first. When Pass 2 writes a report, it records the concepts it reinforced back into `graph.jsonld` via the `reinforces` field, so the next run sees a smaller gap.

This is the *output* side of the same signal-first filter that drives theme selection: a report is the **delta** against each repo's current concept frontier, not a digest of accumulated content ([ADR-0002](docs/adr/0002-reports-as-frontier-diff.md)).

`graph.jsonld` itself follows a schema.org JSON-LD model (`Article` nodes for reports, `Thing` nodes for clusters). The full schema — node types, cluster naming, and integrity rules — is documented in [graph-schema.md](docs/graph-schema.md).

## Cross-line knowledge cycle

In the author's own use, daily-research is also the *write* side of a knowledge cycle shared across several DOI-registered research lines (Agent Knowledge Cycle, Agent Attribution Practice, Contemplative Agent, authorship-strategy). It writes reports into a shared knowledge substrate; each research line consults that substrate read-only and folds findings back into its own concept graph by hand, so a concept one line absorbs can become another line's next research input. If you maintain several research repositories with linked concept graphs, a similar cross-line cycle emerges naturally. This is observed architecture, not a roadmap, and the substrate stays operator-private, so public docs describe it only generically. The filter governing what each line writes and reads is the same signal-first principle — the frontier-diff above is its output-side dual. See [ADR-0003](docs/adr/0003-cross-line-knowledge-cycle.md).

## Customization

### Mapping a track to a research repo

Edit `config.toml` to point each track at a repository:

```toml
[tracks.repo_a]
name = "Research Repo A Contribution"
focus = "Discover external research that reinforces and extends the concept system of research repo A"
target_repo = "/path/to/your/research-repo-a"
target_graph = ".repo-graphs/repo_a.jsonld"   # cwd-relative path after sync
target_doi = "10.xxxx/zenodo.xxxxxxxx"          # optional; the repo's DOI if it has one
sources = [
  "Semantic Scholar (your repo's domain keywords)",
  "arXiv (relevant categories for the repo)",
]
scoring_criteria = [
  { name = "Concept reinforcement", weight = 35, desc = "Reinforces an uncovered / thinly-supported concept" },
  { name = "Research recency", weight = 25, desc = "Latest research or development" },
  { name = "Repo frontier fit", weight = 40, desc = "Serves the repo's next direction" },
]
```

There are no fixed `domains`: the area of interest is derived from the repo's graph at runtime. Define one track per repo you want fed.

### Language

The prompt files (`prompts/`) and report template are written in Japanese. Reports are generated in Japanese by default. To change the output language:

1. Edit the language constraint in `prompts/research-protocol.md`:
   ```
   - 日本語で全て出力すること  →  - Output everything in English
   ```
2. Translate `prompts/research-protocol.md` and `templates/report-template.md` to your preferred language.

### Tuning Research Depth

Edit `prompts/research-protocol.md` to adjust:
- Number of search queries per topic
- Source validation requirements
- Report structure and length

### Changing the Schedule

Edit the plist `StartCalendarInterval`:

```xml
<key>Hour</key>
<integer>7</integer>  <!-- Change to 7 AM -->
```

Then reload: `launchctl unload ... && launchctl load ...`

## Key Design Decisions

| Decision | Why |
|----------|-----|
| Each track = one research repo (coverage-gap driven) | Fixed topic domains caused structural saturation; mapping to a repo graph and prioritizing uncovered concepts prevents domain narrowing ([ADR-0001](docs/adr/0001-research-repo-feedback-engine.md)) |
| Reports as frontier-diff (signal-first output dual) | A report is the delta against each repo's evolving concept graph, not a digest — the output side of the same filter that drives theme selection ([ADR-0002](docs/adr/0002-reports-as-frontier-diff.md)) |
| Local JSON-LD graph instead of external MCP memory | The previous Mem0 MCP integration ran zero times for 32 days due to silent failure; a local `graph.jsonld` is "if the file exists, it works" and fails loudly |
| Read-only repo reference | The pipeline never edits the source repos; contributions flow through vault reports that a human folds back in, avoiding cross-repo pollution |
| 2-pass (Opus + Sonnet) | Opus is stronger at theme selection; Sonnet is faster and cheaper for research and writing |
| Sonnet fallback on Pass 1 failure | Resilience: if Opus times out or fails, Sonnet handles theme selection too |
| `--append-system-prompt-file` (not `--system-prompt-file`) | Preserves Claude Code's default capabilities while adding research instructions |
| `--allowedTools` (not `--dangerously-skip-permissions`) | Minimum-privilege: Pass 1 is read-only, Pass 2 adds write |
| `--max-turns` for timeout control | Process-external timeouts (gtimeout) kill claude via signal, causing data loss |
| Shell orchestration + stdlib Python parser | No pip dependencies at runtime; JSON/TOML parsing lives in one testable `dr_pipeline.py` module instead of scattered inline `python3 -c` snippets (kills test/source copy-paste drift) |
| Real auth probe, not `claude --version` | `--version` succeeds even with an expired OAuth token; a cheap Haiku probe inspects `is_error`/`api_error_status` so expiry fails loudly instead of cascading into a double-401 |
| TOML config | Human-readable, supports nested structures for tracks/criteria |
| `< /dev/null` stdin redirect | Prevents MCP stdio communication from conflicting with terminal stdin (root cause of MCP hangs) |

## Gotchas

- **Claude Code plugins cause hangs** -- If you have Claude Code plugins installed globally, their MCP servers initialize on every `claude -p` call, adding minutes of overhead or causing hangs. Create `.claude/settings.json` in the project root to disable them:
  ```json
  {
    "enabledPlugins": {
      "plugin-name@marketplace": false
    }
  }
  ```
  List each of your installed plugins and set them to `false`. Check installed plugins with `claude plugin list`. There is currently no blanket "disable all" option ([tracking issue](https://github.com/anthropics/claude-code/issues/20873)).
- **OAuth token expires ~4 days** -- Run `claude` interactively periodically to refresh. The pipeline runs a real Haiku auth probe before Pass 1, so an expired token fails loudly with a re-auth notification (and skips the wasteful Sonnet fallback) instead of silently double-failing
- **`ANTHROPIC_API_KEY` must be unset** -- If set, Claude uses per-token billing instead of Max plan. The script handles this with `unset ANTHROPIC_API_KEY`
- **launchd + shell profile** -- `launchd` does NOT source `.zshrc`. All PATH entries must be explicit in the script and plist
- **`--max-turns`** -- Pass 1 uses 15 turns (theme selection), Pass 2 uses 55 turns (research). These are guidelines, not hard limits
- **Do NOT run from inside Claude Code** -- `claude -p` cannot be nested inside another Claude Code session; run it in a separate terminal

## Docs

- [RUNBOOK.md](docs/RUNBOOK.md) / [RUNBOOK.ja.md](docs/RUNBOOK.ja.md) -- Operations: monitoring, troubleshooting, common issues
- [CONTRIB.md](docs/CONTRIB.md) / [CONTRIB.ja.md](docs/CONTRIB.ja.md) -- Development: testing, CLI flags, environment variables
- [graph-schema.md](docs/graph-schema.md) -- `graph.jsonld` schema: node types, cluster naming, integrity rules
- [ADR-0001](docs/adr/0001-research-repo-feedback-engine.md) -- Why each track maps to a research repository
- [ADR-0002](docs/adr/0002-reports-as-frontier-diff.md) -- Reports as frontier-diff: signal-first applied to output
- [ADR-0003](docs/adr/0003-cross-line-knowledge-cycle.md) -- daily-research as the write side of a cross-line knowledge cycle

## License

[MIT](LICENSE)
