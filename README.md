# daily-research

Automated daily research reports powered by [Claude Code](https://docs.anthropic.com/en/docs/claude-code) non-interactive mode and macOS `launchd`.

**Zero Python. Just shell scripts + prompt files.**

Every morning at 5:00 AM, Claude autonomously browses the web, selects trending topics, conducts multi-stage deep research, and writes reports directly into your [Obsidian](https://obsidian.md) vault.

## How It Works

```
launchd (AM 5:00)
  └─ daily-research.sh
       ├── Pass 1: Opus (theme selection)
       │     ├── Read config.toml       # What to research
       │     ├── Read past_topics.json  # Avoid duplicates
       │     ├── WebSearch              # Latest trends
       │     └── Score & select 2 topics
       │
       ├── Pass 2: Sonnet (research & writing)
       │     ├── WebSearch x 20-30      # Multi-stage research
       │     ├── WebFetch (primary sources)
       │     └── Write 2 reports        # → Obsidian vault
       │
       └── Eval: Opus (quality scoring, non-fatal)
             ├── 6 dimensions x 2 reports
             └── Append to scores.jsonl
```

**2-pass architecture**: Opus handles theme selection (deep reasoning), Sonnet handles research and writing (speed + cost efficiency). If Pass 1 fails, Sonnet handles everything as a fallback.

The key insight: Claude Code's `-p` flag turns it into a fully autonomous research agent. No API plumbing, no Python, no orchestration framework. The intelligence lives in the prompt.

## Features

- **2-pass model routing** -- Opus for theme selection, Sonnet for research (best of both worlds)
- **Configurable research tracks** -- Define topics, sources, and scoring criteria in `config.toml`
- **Topic deduplication** -- `past_topics.json` prevents covering the same theme twice within 30 days
- **Multi-stage deep research** -- Not just a summary; generates research questions, searches 20-30 times, cross-validates sources
- **Weighted topic scoring** -- Novelty, momentum, buildability, and "whisper trend" scores
- **Obsidian-native output** -- Reports with YAML frontmatter, ready for your vault
- **Robust execution** -- Lock files, log rotation, auth checks, macOS notifications, automatic fallback
- **Automated quality evaluation** -- LLM-as-Judge scores each report on 6 dimensions (30-point scale)

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | `brew install claude` or via npm |
| [Claude Max plan](https://claude.ai) | For zero-cost non-interactive usage |
| macOS | Uses `launchd` for scheduling (Linux users: adapt to `cron` or `systemd`) |
| Obsidian (optional) | Any markdown-compatible tool works |

## Quick Start

```bash
# 1. Clone
git clone https://github.com/shimo4228/daily-research.git
cd daily-research

# 2. Configure
cp config.example.toml config.toml
# Edit config.toml: set vault_path and customize tracks

# 3. Make scripts executable
chmod +x scripts/daily-research.sh scripts/eval-run.sh scripts/check-auth.sh

# 4. Verify Claude auth
./scripts/check-auth.sh

# 5. Test run (manual)
./scripts/daily-research.sh

# 6. Schedule with launchd (optional)
cp com.example.daily-research.plist com.daily-research.plist
# Edit: replace YOUR_USERNAME with your macOS username
ln -sf "$(pwd)/com.daily-research.plist" ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.daily-research.plist
```

## Project Structure

```
daily-research/
├── config.example.toml         # Research tracks, scoring, output settings
├── prompts/
│   ├── theme-selection-prompt.md  # Pass 1: Theme selection (Opus)
│   ├── task-prompt.md             # Pass 2: Research instruction (Sonnet)
│   └── research-protocol.md      # Pass 2: Research protocol (system prompt)
├── templates/
│   └── report-template.md      # Report format with YAML frontmatter
├── scripts/
│   ├── daily-research.sh       # Main entry point (launchd calls this)
│   ├── eval-run.sh             # LLM-as-Judge evaluation (post-run)
│   └── check-auth.sh           # OAuth token health check
├── evals/
│   ├── prompts/                # Judge rubrics (6 dimensions + system prompt)
│   ├── scores.jsonl            # Score log (append-only, gitignored)
│   └── scores.example.jsonl    # Schema reference
├── com.example.daily-research.plist  # launchd schedule template
├── tests/
│   ├── test-daily-research.bats     # Unit tests
│   ├── test-e2e-mock.bats          # E2E mock tests
│   └── test-eval.bats              # Evaluation framework tests
└── docs/
    ├── RUNBOOK.md / RUNBOOK.ja.md   # Operations guide
    ├── CONTRIB.md / CONTRIB.ja.md   # Development guide
    └── plans/                       # Future expansion plans
```

## Evaluation Framework

After each successful run, an automated LLM-as-Judge evaluation scores every generated report. This runs as a non-fatal hook -- evaluation failures never block the main pipeline.

Each report is scored by Opus on 6 independent dimensions (1-5 scale, 30 points total):

| Dimension | What It Measures |
|-----------|-----------------|
| Factual Grounding | Source quality and claim verification |
| Depth of Analysis | Beyond surface-level summaries |
| Coherence | Logical flow and structure |
| Specificity | Concrete examples vs. abstract statements |
| Novelty | Fresh insights beyond common knowledge |
| Actionability | Practical development ideas |

Scores are appended to `evals/scores.jsonl`. The `pipeline_version` field enables before/after comparisons when the pipeline changes. See [CONTRIB.md](docs/CONTRIB.md) for full details.

## Customization

### Adding a Research Track

Edit `config.toml` to add new tracks:

```toml
[tracks.finance]
name = "Finance & Markets"
focus = "Fintech, DeFi, and market trends"
sources = [
  "Bloomberg Technology",
  "TechCrunch Fintech",
]
scoring_criteria = [
  { name = "Novelty", weight = 30, desc = "Not covered recently" },
  { name = "Momentum", weight = 30, desc = "Actively evolving" },
  { name = "Actionability", weight = 40, desc = "Can act on this insight" },
]
```

### Language

The prompt files (`prompts/`) and report template are written in Japanese. Reports will be generated in Japanese by default. To change the output language:

1. Edit the language constraint in `prompts/research-protocol.md` line 10:
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
| 2-pass (Opus + Sonnet) | Opus excels at theme selection (+28% in blind eval); Sonnet is faster and cheaper for research/writing |
| Sonnet fallback on Pass 1 failure | Resilience: if Opus times out or fails, Sonnet handles everything |
| `--append-system-prompt-file` (not `--system-prompt-file`) | Preserves Claude Code's default capabilities while adding research instructions |
| `--allowedTools` (not `--dangerously-skip-permissions`) | Minimum-privilege: Pass 1 is read-only, Pass 2 adds write |
| `--max-turns` for timeout control | Process-external timeouts (gtimeout) kill claude via signal, causing data loss |
| Shell scripts only | Zero dependencies beyond Claude Code CLI; trivial to understand and modify |
| TOML config | Human-readable, supports nested structures for tracks/criteria |
| LLM-as-Judge (non-fatal) | Automated quality feedback without blocking production; 6 independent dimensions reduce single-score bias |
| `stream-json` for Pass 1 | Captures tool usage counts alongside result for cost/performance monitoring |

## Gotchas

- **OAuth token expires ~4 days** -- Run `claude` interactively periodically to refresh
- **`ANTHROPIC_API_KEY` must be unset** -- If set, Claude uses per-token billing instead of Max plan. The script handles this with `unset ANTHROPIC_API_KEY`
- **launchd + shell profile** -- `launchd` does NOT source `.zshrc`. All PATH entries must be explicit in the script and plist
- **`--max-turns`** -- Pass 1 uses 15 turns (theme selection), Pass 2 uses 40 turns (research). These are guidelines, not hard limits
- **Do NOT run from inside Claude Code** -- `claude -p` cannot be nested inside another Claude Code session

## Docs

- [RUNBOOK.md](docs/RUNBOOK.md) / [RUNBOOK.ja.md](docs/RUNBOOK.ja.md) -- Operations: monitoring, troubleshooting, common issues
- [CONTRIB.md](docs/CONTRIB.md) / [CONTRIB.ja.md](docs/CONTRIB.ja.md) -- Development: testing, CLI flags, environment variables

## License

[MIT](LICENSE)
