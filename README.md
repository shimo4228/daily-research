# daily-research

Automated daily research reports powered by [Claude Code](https://docs.anthropic.com/en/docs/claude-code) non-interactive mode and macOS `launchd`.

**Zero Python. Just shell scripts + prompt files.**

Every morning at 5:00 AM, Claude autonomously browses the web, selects trending topics, conducts multi-stage deep research, and writes reports directly into your [Obsidian](https://obsidian.md) vault.

## How It Works

```
launchd (AM 5:00)
  └─ daily-research.sh
       └─ claude -p "Run today's research"
            ├── Read config.toml          # What to research
            ├── Read past_topics.json     # Avoid duplicates
            ├── WebSearch x 20-30         # Multi-stage research
            ├── WebFetch (primary sources) # Deep dive
            ├── Score & select topics     # Weighted criteria
            └── Write reports             # → Obsidian vault
```

The key insight: Claude Code's `-p` flag turns it into a fully autonomous research agent. No API plumbing, no Python, no orchestration framework. The intelligence lives in the prompt.

## Features

- **Configurable research tracks** -- Define topics, sources, and scoring criteria in `config.toml`
- **Topic deduplication** -- `past_topics.json` prevents covering the same theme twice within 30 days
- **Multi-stage deep research** -- Not just a summary; generates research questions, searches 20-30 times, cross-validates sources
- **Weighted topic scoring** -- Novelty, momentum, buildability, and "whisper trend" scores
- **Obsidian-native output** -- Reports with YAML frontmatter, ready for your vault
- **Robust execution** -- Lock files, timeouts, log rotation, auth checks, macOS notifications

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
git clone https://github.com/your-username/daily-research.git
cd daily-research

# 2. Configure
cp config.example.toml config.toml
# Edit config.toml: set vault_path and customize tracks

# 3. Make scripts executable
chmod +x scripts/daily-research.sh scripts/check-auth.sh

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
│   ├── task-prompt.md          # What to tell Claude (the -p argument)
│   └── research-protocol.md    # How to research (system prompt)
├── templates/
│   └── report-template.md      # Report format with YAML frontmatter
├── scripts/
│   ├── daily-research.sh       # Main entry point (launchd calls this)
│   └── check-auth.sh           # OAuth token health check
├── com.example.daily-research.plist  # launchd schedule template
├── tests/
│   └── test-daily-research.bats     # Shell tests
└── docs/
    ├── RUNBOOK.md              # Operations guide
    └── CONTRIB.md              # Development guide
```

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

The prompt files (`prompts/`) and report template are written in Japanese. Reports will be generated in Japanese by default. To change the output language, translate `prompts/research-protocol.md` and `templates/report-template.md` to your preferred language.

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
| `--append-system-prompt-file` (not `--system-prompt-file`) | Preserves Claude Code's default capabilities while adding research instructions |
| `--allowedTools` (not `--dangerously-skip-permissions`) | Minimum-privilege: only grants web search, file read/write |
| Shell scripts only | Zero dependencies beyond Claude Code CLI; trivial to understand and modify |
| TOML config | Human-readable, supports nested structures for tracks/criteria |

## Gotchas

- **OAuth token expires ~4 days** -- Run `claude` interactively periodically to refresh
- **`ANTHROPIC_API_KEY` must be unset** -- If set, Claude uses per-token billing instead of Max plan. The script handles this with `unset ANTHROPIC_API_KEY`
- **launchd + shell profile** -- `launchd` does NOT source `.zshrc`. All PATH entries must be explicit in the script and plist
- **`--max-turns 40`** -- This is a guideline, not a hard limit. Complex research may use more turns

## Docs

- [RUNBOOK.md](docs/RUNBOOK.md) -- Operations: monitoring, troubleshooting, common issues
- [CONTRIB.md](docs/CONTRIB.md) -- Development: testing, CLI flags, environment variables

## License

[MIT](LICENSE)
