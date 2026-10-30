#!/usr/bin/env python3
"""Count how often daily-research notes were adopted into the operator's repos.

Read-only, stdlib only, outside the pipeline (nothing in scripts/ calls it). It exists so the
baseline and the later checks of the report-quality-and-cost plan use one definition.

For each note `{date}_{line}_{slug}.md` in the vault output dir dated in [--since, --until], take
the URLs in its `## ソース` section and look them up in the git-tracked files of every
`target_repo` in config.toml plus each `--extra-repo` (default: ~/.claude). Per note:

- adopted: some URL first entered a repo on or after the note date, within --window-days
  (0 = no limit). "First entered" is the oldest commit that adds the string (`git log -S`).
- re-cited: not adopted, and some URL was already in a repo before the note date. This is the
  corroboration shape ADR-0008 warns about: the note re-presents what the repo already holds.

Ignored: URLs matching config `self_signals`, Zenodo records (the operator's own DOIs), and
jrp notes (`_jrp_` in the name). The Obsidian wiki is not searched because it ingests every
note automatically, so a hit there says nothing about the reader.

Limits: an idea adopted without its URL is missed, and a URL the operator found on their own
counts as adopted. Treat the rates as a sanity check beside the reader's own judgment.

Usage: python3 adoption_backtest.py --since 2026-08-04 [--until 2026-10-31] [--window-days 21]
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import re
import subprocess
import tomllib
from collections import defaultdict

URL_RE = re.compile(r"https?://[^\s)>\]\"'`|]+")
REPO_URL_PATTERN = r"https?://[^ )>\"`|]+"
IGNORED_SUBSTRINGS = ("zenodo.org/records", "doi.org/10.5281/zenodo")


def normalize(url: str) -> str:
    return url.rstrip(".,;:").rstrip("/")


def sources_section(text: str) -> str:
    if "## ソース" not in text:
        return ""
    tail = text.split("## ソース")[-1]
    return tail.split("\n## ")[0]


def line_of(rest: str, lines: list[str]) -> str:
    for name in sorted(lines, key=len, reverse=True):
        if rest.startswith(name + "_"):
            return name
    return rest.split("_")[0]


def repo_url_index(repos: list[str]) -> dict[str, dict[str, str]]:
    """lowercased URL -> {repo path: URL as written in that repo}."""
    index: dict[str, dict[str, str]] = defaultdict(dict)
    for repo in repos:
        if not os.path.isdir(os.path.join(repo, ".git")) and not os.path.isfile(
            os.path.join(repo, ".git")
        ):
            continue
        out = subprocess.run(
            ["git", "-C", repo, "grep", "-ohIE", REPO_URL_PATTERN],
            capture_output=True,
            text=True,
            check=False,
        ).stdout
        for raw in out.split():
            url = normalize(raw)
            index[url.lower()].setdefault(repo, url)
    return index


def first_added(repo: str, url: str, cache: dict[tuple[str, str], str | None]) -> str | None:
    key = (repo, url)
    if key not in cache:
        out = subprocess.run(
            ["git", "-C", repo, "log", "-S", url, "--reverse", "--format=%ad", "--date=short"],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.split()
        cache[key] = out[0] if out else None
    return cache[key]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default="config.toml")
    ap.add_argument("--since", required=True)
    ap.add_argument("--until", default=dt.date.today().isoformat())
    ap.add_argument("--window-days", type=int, default=21)
    ap.add_argument("--extra-repo", action="append", default=None)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    with open(args.config, "rb") as f:
        cfg = tomllib.load(f)
    general = cfg["general"]
    out_dir = os.path.join(general["vault_path"], general["output_dir"])
    self_signals = [s.lower() for s in general.get("self_signals", [])]
    tracks = cfg.get("tracks", {})
    repos = [r["target_repo"] for t in tracks.values() for r in t.get("repos", [])]
    extra = args.extra_repo if args.extra_repo is not None else [os.path.expanduser("~/.claude")]
    repos += [os.path.expanduser(p) for p in extra]

    index = repo_url_index(repos)
    cache: dict[tuple[str, str], str | None] = {}
    per_line: dict[str, dict[str, int]] = defaultdict(
        lambda: {"notes": 0, "adopted": 0, "recited": 0}
    )

    for path in sorted(glob.glob(os.path.join(out_dir, "20??-??-??_*.md"))):
        name = os.path.basename(path)
        date = name[:10]
        if not (args.since <= date <= args.until) or "_jrp_" in name:
            continue
        line = line_of(name[11:], list(tracks))
        with open(path, encoding="utf-8", errors="ignore") as f:
            urls = {normalize(u) for u in URL_RE.findall(sources_section(f.read()))}
        note_day = dt.date.fromisoformat(date)
        adopted = recited = False
        for url in urls:
            low = url.lower()
            if any(s in low for s in self_signals) or any(s in low for s in IGNORED_SUBSTRINGS):
                continue
            for repo, written in index.get(low, {}).items():
                first = first_added(repo, written, cache)
                if first is None:
                    continue
                first_day = dt.date.fromisoformat(first)
                lag = (first_day - note_day).days
                if lag >= 0 and (args.window_days == 0 or lag <= args.window_days):
                    adopted = True
                elif lag < 0:
                    recited = True
        stats = per_line[line]
        stats["notes"] += 1
        stats["adopted"] += adopted
        stats["recited"] += (not adopted) and recited

    total = {k: sum(s[k] for s in per_line.values()) for k in ("notes", "adopted", "recited")}
    if args.json:
        print(
            json.dumps(
                {"args": vars(args), "per_line": per_line, "total": total}, ensure_ascii=False
            )
        )
        return 0
    print(f"since {args.since} until {args.until}, window {args.window_days or 'unlimited'} days")
    print(f"{'line':<14}{'notes':>6}{'adopted':>9}{'re-cited':>10}")
    for line, s in sorted(per_line.items()):
        print(f"{line:<14}{s['notes']:>6}{s['adopted']:>9}{s['recited']:>10}")
    n = total["notes"] or 1
    print(
        f"{'total':<14}{total['notes']:>6}{total['adopted']:>9}{total['recited']:>10}"
        f"   adopted {total['adopted'] / n:.0%}, re-cited {total['recited'] / n:.0%}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
