#!/usr/bin/env python3
"""Isolated two-stage discovery runner. Runtime dependencies: Python 3.11 stdlib."""

from __future__ import annotations

import argparse
from datetime import date, datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import tomllib
from urllib.parse import urlparse

from dr_pipeline import _pass_metrics, _sum_pass_metrics

ROOT = Path(__file__).resolve().parents[2]


class DiscoveryError(ValueError):
    """An incomplete or unsafe run must not become a report."""


def obj(properties):
    return {
        "type": "object",
        "properties": properties,
        "required": list(properties),
        "additionalProperties": False,
    }


def array(item, **limits):
    return {"type": "array", "items": item, **limits}


TEXT = {"type": "string", "minLength": 1}
SOURCE = obj(
    dict(
        url=TEXT,
        title=TEXT,
        published_at={"type": ["string", "null"]},
        checked_at=TEXT,
        evidence=TEXT,
        access={"enum": ["verified", "unresolved"]},
    )
)
ARTICLE = obj(dict(title=TEXT, body=TEXT, source_urls=array(TEXT, minItems=1)))
RESEARCH_SCHEMA = obj(
    {
        "candidates": array(
            obj(
                dict(title=TEXT, possibility=TEXT, evidence=TEXT, sources=array(SOURCE))
            )
        )
    }
)
EDITORIAL_SCHEMA = obj(
    dict(
        kind={"enum": ["normal", "briefs", "quiet"]},
        title=TEXT,
        tags=array(TEXT),
        main={"anyOf": [ARTICLE, {"type": "null"}]},
        briefs=array(ARTICLE, maxItems=3),
        sources=array(SOURCE),
        opportunities=array(obj(dict(what=TEXT, url=TEXT, expires=TEXT))),
    )
)


def validate_schema(value, schema, path="output"):
    """Validate our deliberately small schema subset without a runtime dependency."""
    if "anyOf" in schema:
        for option in schema["anyOf"]:
            try:
                validate_schema(value, option, path)
                return
            except DiscoveryError:
                pass
        raise DiscoveryError(f"{path}: no allowed shape matched")
    if "enum" in schema and value not in schema["enum"]:
        raise DiscoveryError(f"{path}: invalid value")
    types = schema.get("type", [])
    types = [types] if isinstance(types, str) else types
    valid = {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "null": value is None,
    }
    if types and not any(valid[t] for t in types):
        raise DiscoveryError(f"{path}: invalid type")
    if isinstance(value, str) and "minLength" in schema and not value.strip():
        raise DiscoveryError(f"{path}: empty text")
    if "properties" in schema:
        if set(value) != set(schema["properties"]):
            raise DiscoveryError(f"{path}: unexpected or missing fields")
        for key, child in schema["properties"].items():
            validate_schema(value[key], child, f"{path}.{key}")
    if schema.get("type") == "array":
        if not schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", 10000):
            raise DiscoveryError(f"{path}: invalid item count")
        for item in value:
            validate_schema(item, schema["items"], path + "[]")


def valid_url(value):
    parsed = urlparse(value)
    if (
        parsed.scheme not in ("http", "https")
        or not parsed.hostname
        or parsed.username
        or any(c.isspace() for c in value)
    ):
        raise DiscoveryError(
            "Source URL must be an absolute HTTP(S) URL without credentials"
        )


def validate_sources(sources):
    for source in sources:
        valid_url(source["url"])
        date.fromisoformat(source["checked_at"])


def validate_edition(value):
    validate_schema(value, EDITORIAL_SCHEMA)
    validate_sources(value["sources"])
    kind = value["kind"]
    if kind == "normal" and value["main"] is None:
        raise DiscoveryError("Normal edition needs a main article")
    if kind != "normal" and value["main"] is not None:
        raise DiscoveryError("Only normal editions have a main article")
    if kind == "briefs" and not value["briefs"]:
        raise DiscoveryError("Brief edition needs a brief")
    if kind == "quiet" and any(
        value[k] for k in ("briefs", "sources", "opportunities")
    ):
        raise DiscoveryError("Quiet edition cannot contain articles or sources")
    sources = {s["url"]: s for s in value["sources"]}
    if len(sources) != len(value["sources"]):
        raise DiscoveryError("Duplicate source URLs")
    for article in ([value["main"]] if value["main"] else []) + value["briefs"]:
        refs = article["source_urls"]
        if any(url not in sources for url in refs):
            raise DiscoveryError("Article references an unknown source")
        if not any(sources[url]["access"] == "verified" for url in refs):
            raise DiscoveryError("Article has no directly verified evidence")
    for opportunity in value["opportunities"]:
        valid_url(opportunity["url"])
        date.fromisoformat(opportunity["expires"])


def decode_response(raw):
    try:
        envelope = json.loads(raw)
        if not isinstance(envelope, dict) or envelope.get("is_error"):
            raise DiscoveryError("Claude returned an error")
        result = envelope.get("structured_output")
        if result is None:
            result = json.loads(envelope.get("result", ""))
        if not isinstance(result, dict):
            raise DiscoveryError("Claude returned no structured object")
        return result
    except (json.JSONDecodeError, TypeError) as exc:
        raise DiscoveryError("Claude returned invalid structured JSON") from exc


def write_json(path, value):
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def record_json(path, value):
    """Operational metadata must never undo an already published result."""
    try:
        write_json(path, value)
    except OSError as exc:
        print(f"WARN: cannot record {path.name}: {exc}", file=sys.stderr)


def run_stage(cli, stage, settings, payload, protocol, run_dir):
    schema = RESEARCH_SCHEMA if stage == "research" else EDITORIAL_SCHEMA
    timeout = settings.get("timeout_seconds", 1500 if stage == "research" else 1200)
    turns = settings.get("max_turns", 55 if stage == "research" else 45)
    command = [
        cli,
        "-p",
        "--safe-mode",
        "--tools",
        "WebSearch,WebFetch",
        "--allowedTools",
        "WebSearch,WebFetch",
        "--disallowedTools",
        "mcp__*",
        "--permission-prompts",
        "none",
        "--permission-mode",
        "default",
        "--model",
        settings.get("model", "opus"),
        "--output-format",
        "json",
        "--json-schema",
        json.dumps(schema),
        "--append-system-prompt-file",
        str(protocol),
        "--no-session-persistence",
        "--max-turns",
        str(turns),
    ]
    write_json(run_dir / f"{stage}-input.json", payload)
    # Make the exact instructions/schema reviewable even after future prompt edits.
    (run_dir / f"{stage}-protocol.md").write_text(
        protocol.read_text(encoding="utf-8"), encoding="utf-8"
    )
    write_json(run_dir / f"{stage}-schema.json", schema)
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="daily-discovery-") as workdir:
        for attempt in (1, 2):
            attempt_started = time.monotonic()
            try:
                response = subprocess.run(
                    command,
                    input=json.dumps(payload, ensure_ascii=False),
                    capture_output=True,
                    text=True,
                    cwd=workdir,
                    timeout=timeout,
                    check=False,
                )
            except subprocess.TimeoutExpired as exc:
                # A full research timeout is a budget exhaustion, not a transient retry.
                record_json(
                    run_dir / f"{stage}-{attempt}.json",
                    {
                        "is_error": True,
                        "termination": "timeout",
                        "duration_ms": round(
                            (time.monotonic() - attempt_started) * 1000
                        ),
                        "total_cost_usd": None,
                    },
                )
                raise DiscoveryError(f"{stage} timed out after {timeout}s") from exc
            (run_dir / f"{stage}-{attempt}.json").write_text(
                response.stdout, encoding="utf-8"
            )
            (run_dir / f"{stage}-{attempt}.stderr").write_text(
                response.stderr, encoding="utf-8"
            )
            try:
                envelope = json.loads(response.stdout)
            except json.JSONDecodeError:
                envelope = {}
            if not isinstance(envelope, dict):
                raise DiscoveryError(f"{stage} returned an invalid envelope")
            if response.returncode == 0 and not envelope.get("is_error"):
                result = decode_response(response.stdout)
                validate_schema(result, schema)
                if stage == "research":
                    for candidate in result["candidates"]:
                        validate_sources(candidate["sources"])
                envelope = json.loads(response.stdout)
                return result, {
                    "attempts": attempt,
                    "duration_seconds": round(time.monotonic() - started, 2),
                    "usage": envelope.get("usage", {}),
                    "num_turns": envelope.get("num_turns"),
                    "estimated_cost_usd": envelope.get("total_cost_usd"),
                }
            transient = re.search(
                r"overloaded|rate.?limit|\b429\b|\b50[234]\b|connection reset|temporarily unavailable",
                response.stderr + response.stdout,
                re.I,
            )
            if envelope.get("api_error_status") in (401, 403):
                transient = None
            if attempt == 2 or not transient:
                raise DiscoveryError(
                    f"{stage} failed (exit {response.returncode}); see archived stderr"
                )
    raise DiscoveryError(f"{stage} did not complete")


def recent_history(directory, today):
    """A bounded index from published frontmatter/headings; never a playbook."""
    history = []
    if not directory.exists():
        return history
    for path in sorted(directory.glob("*.md"), reverse=True):
        try:
            day = date.fromisoformat(path.name[:10])
        except ValueError:
            continue
        if not today - timedelta(days=30) <= day < today:
            continue
        text = path.read_text(encoding="utf-8")[:50000]
        headings = [
            line[:300]
            for line in text.splitlines()
            if line.startswith(("# ", "## ", "title:"))
        ]
        history.append({"date": day.isoformat(), "headings": headings[:8]})
        if len(history) >= 100:
            break
    return history


def render(value, day):
    q = lambda text: json.dumps(text, ensure_ascii=False)
    lines = [
        "---",
        f"date: {day}",
        f"topic: {q(value['title'])}",
        "category: discovery",
        f"sources: {len(value['sources'])}",
        f"actionable: {len(value['opportunities'])}",
        f"kind: {value['kind']}",
        "pipeline_version: 2",
        f"tags: {q(value['tags'])}",
        "---",
        "",
        f"# {value['title']}",
        "",
    ]
    for article in ([value["main"]] if value["main"] else []) + value["briefs"]:
        lines += [f"## {article['title']}", "", article["body"], ""]
    if value["opportunities"]:
        lines += ["## 機会メモ", ""]
        lines += [
            f"- {o['what']} — {o['expires']}: {o['url']}"
            for o in value["opportunities"]
        ]
        lines += [""]
    lines += ["## ソース", ""]
    for index, source in enumerate(value["sources"], 1):
        title = source["title"].replace("[", "\\[").replace("]", "\\]")
        lines += [
            f"{index}. [{title}]({source['url']}) — 確認日: {source['checked_at']}"
            + ("（未検証）" if source["access"] == "unresolved" else "")
        ]
    return "\n".join(lines) + "\n"


def run(config, day, preview=False, claude="claude"):
    today = date.fromisoformat(day)
    with Path(config).open("rb") as handle:
        cfg = tomllib.load(handle)
    if "tracks" in cfg or not isinstance(cfg.get("reader"), dict):
        raise DiscoveryError(
            "Legacy config: migrate to [reader], [research], [editorial] using config.example.toml"
        )
    general = cfg["general"]
    output = Path(general["vault_path"]).expanduser() / general["output_dir"]
    relative_output = Path(general["output_dir"])
    if relative_output.is_absolute() or ".." in relative_output.parts:
        raise DiscoveryError("output_dir must stay inside vault_path")
    profile_path = (
        ROOT / cfg.get("reader", {}).get("profile", "reader-profile.md")
    ).resolve()
    if not profile_path.is_relative_to(ROOT):
        raise DiscoveryError("Reader profile must be inside this repository")
    profile = profile_path.read_text(encoding="utf-8")
    if not profile.strip() or len(profile) > 16000:
        raise DiscoveryError("Reader profile must contain 1–16000 characters")
    for stage in ("research", "editorial"):
        settings = cfg.get(stage, {})
        for field in ("timeout_seconds", "max_turns"):
            if field in settings and (
                type(settings[field]) is not int or settings[field] <= 0
            ):
                raise DiscoveryError(f"{stage}.{field} must be a positive integer")
        if (
            not isinstance(settings.get("model", "opus"), str)
            or not settings.get("model", "opus").strip()
        ):
            raise DiscoveryError(f"{stage}.model must be nonempty")
    signals = general.get("self_signals", [])
    if not isinstance(signals, list) or any(
        not isinstance(item, str) for item in signals
    ):
        raise DiscoveryError("self_signals must be a list of strings")
    protocols = [
        ROOT / "prompts" / name
        for name in ("discovery-protocol.md", "editorial-protocol.md")
    ]
    for protocol in protocols:
        if not protocol.read_text(encoding="utf-8").strip():
            raise DiscoveryError("Empty protocol")
    state = ROOT / "state" / "discovery"
    destination = output / f"{day}_discovery_edition.md"
    quiet_marker = state / f"{day}.quiet.json"
    if not preview and (destination.exists() or quiet_marker.exists()):
        if destination.exists() and destination.stat().st_size == 0:
            raise DiscoveryError("Existing report is empty; inspect before rerunning")
        return dict(
            status="skipped",
            published=False,
            kind=None,
            file=str(destination) if destination.exists() else None,
            run_dir=None,
        )
    base = ROOT / ".notes" / "discovery-runs" if preview else state / "runs"
    base.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix=f"{day}_", dir=base))
    os.chmod(run_dir, 0o700)
    metrics = {
        "pipeline_version": 2,
        "date": day,
        "source": "test" if preview else "live",
        "ts": datetime.now(timezone.utc).isoformat(),
        "report_count": 0,
        "fallback_used": False,
        "pass1": None,
        "pass2": None,
        "clarity_pass": None,
        "lint": None,
        "stages": {},
    }
    try:
        research, metrics["stages"]["research"] = run_stage(
            claude,
            "research",
            cfg.get("research", {}),
            dict(date=day, reader_profile=profile, self_signals=signals),
            protocols[0],
            run_dir,
        )
        write_json(run_dir / "research.json", research)
        edited, metrics["stages"]["editorial"] = run_stage(
            claude,
            "editorial",
            cfg.get("editorial", {}),
            dict(
                date=day,
                reader_profile=profile,
                research=research,
                history=recent_history(output, today),
            ),
            protocols[1],
            run_dir,
        )
        validate_edition(edited)
        write_json(run_dir / "edition.json", edited)
        report = run_dir / destination.name
        if edited["kind"] != "quiet":
            report.write_text(render(edited, day), encoding="utf-8")
        if preview:
            result = dict(
                status="preview",
                published=False,
                kind=edited["kind"],
                file=str(report) if report.exists() else None,
                run_dir=str(run_dir),
            )
        elif edited["kind"] == "quiet":
            write_json(
                quiet_marker,
                {"date": day, "run_dir": str(run_dir), "title": edited["title"]},
            )
            result = dict(
                status="quiet",
                published=False,
                kind="quiet",
                file=None,
                run_dir=str(run_dir),
            )
        else:
            output.mkdir(parents=True, exist_ok=True)
            # link() atomically refuses replacement; temporary file stays on destination filesystem.
            with tempfile.NamedTemporaryFile(
                dir=output, prefix=".discovery-", delete=False
            ) as handle:
                temporary = Path(handle.name)
                handle.write(report.read_bytes())
                handle.flush()
                os.fsync(handle.fileno())
            try:
                os.link(temporary, destination)
            finally:
                temporary.unlink()
            result = dict(
                status="published",
                published=True,
                kind=edited["kind"],
                file=str(destination),
                run_dir=str(run_dir),
            )
        metrics["final_class"] = "OK"
        metrics["kind"] = edited["kind"]
        metrics["report_count"] = int(edited["kind"] != "quiet")
        record_json(run_dir / "result.json", result)
        return result
    except Exception as exc:
        metrics["final_class"] = "E_NO_REPORT"
        record_json(
            run_dir / "error.json", {"error": str(exc), "type": type(exc).__name__}
        )
        raise
    finally:
        attempted = []
        cost_complete = True
        for stage in ("research", "editorial"):
            parts = []
            stage_cost_complete = True
            files = sorted(run_dir.glob(f"{stage}-[12].json"))
            for raw_file in files:
                try:
                    raw = json.loads(raw_file.read_text(encoding="utf-8"))
                    stage_cost_complete &= raw.get("total_cost_usd") is not None
                    parts.append(_pass_metrics(raw))
                except (OSError, ValueError, TypeError, AttributeError):
                    stage_cost_complete = False
                    continue
            if files:
                stats = metrics["stages"].setdefault(stage, {})
                stats.update(_sum_pass_metrics(parts) or {})
                stats["attempts"] = len(files)
                stats["cost_complete"] = stage_cost_complete
                if not stage_cost_complete:
                    stats["cost"] = None
                metrics["fallback_used"] |= len(files) > 1
            cost_complete &= stage_cost_complete
            attempted.extend(parts)
        metrics["pass2"] = _sum_pass_metrics(attempted)
        metrics["total_cost"] = (metrics["pass2"] or {}).get("cost", 0)
        metrics["cost_complete"] = cost_complete
        if not cost_complete:
            metrics["total_cost"] = None
            if metrics["pass2"]:
                metrics["pass2"]["cost"] = None
        record_json(run_dir / "metrics.json", metrics)
        if not preview:
            # Operational history remains compatible; previews never touch it.
            try:
                with (ROOT / "metrics.jsonl").open("a", encoding="utf-8") as stream:
                    stream.write(json.dumps(metrics, ensure_ascii=False) + "\n")
            except OSError as exc:
                print(f"WARN: cannot append metrics: {exc}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["run"])
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--date", required=True)
    parser.add_argument("--preview", action="store_true")
    parser.add_argument("--claude", default="claude")
    args = parser.parse_args()
    try:
        result = run(args.config, args.date, args.preview, args.claude)
    except (DiscoveryError, OSError, ValueError, KeyError) as exc:
        print(json.dumps({"status": "error", "error": str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
