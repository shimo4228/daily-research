"""Discovery boundaries: evidence validation, isolation and idempotent delivery."""

import json
import subprocess

import pytest

import discovery as d


def source():
    return dict(
        url="https://example.org/work",
        title="Work",
        published_at=None,
        checked_at="2026-09-06",
        evidence="Directly read work",
        access="verified",
    )


def edition(kind="normal"):
    article = dict(
        title="A new possibility",
        body="A grounded discovery.",
        source_urls=[source()["url"]],
    )
    return dict(
        kind=kind,
        title="Morning",
        tags=["discovery"],
        main=article if kind == "normal" else None,
        briefs=[article] if kind == "briefs" else [],
        sources=[] if kind == "quiet" else [source()],
        opportunities=[],
    )


def test_envelope_rejects_error_and_missing_output():
    for value in (
        {"is_error": True, "structured_output": edition()},
        {"result": "not json"},
    ):
        with pytest.raises(d.DiscoveryError):
            d.decode_response(json.dumps(value))
    assert d.decode_response(json.dumps({"structured_output": edition()})) == edition()


def test_invalid_evidence_and_kind_cannot_publish():
    value = edition()
    value["sources"][0]["access"] = "unresolved"
    with pytest.raises(d.DiscoveryError):
        d.validate_edition(value)
    value = edition("quiet")
    value["briefs"] = edition("briefs")["briefs"]
    with pytest.raises(d.DiscoveryError):
        d.validate_edition(value)


def test_stage_isolated_and_only_transient_retry(tmp_path, monkeypatch):
    protocol = tmp_path / "protocol.md"
    protocol.write_text("Search the web.")
    calls = []

    def fake_run(args, **kwargs):
        calls.append((args, kwargs))
        if len(calls) == 1:
            return subprocess.CompletedProcess(args, 1, "", "503 overloaded")
        return subprocess.CompletedProcess(
            args, 0, json.dumps({"structured_output": {"candidates": []}}), ""
        )

    monkeypatch.setattr(d.subprocess, "run", fake_run)
    result, metrics = d.run_stage(
        "claude", "research", {}, {"date": "2026-09-06"}, protocol, tmp_path
    )
    assert result == {"candidates": []}
    assert metrics["attempts"] == 2
    args, kwargs = calls[0]
    assert "--safe-mode" in args and "--no-session-persistence" in args
    assert args[args.index("--tools") + 1] == "WebSearch,WebFetch"
    assert kwargs["cwd"] != d.ROOT
    assert "history" not in kwargs["input"]


def setup_root(tmp_path, monkeypatch):
    monkeypatch.setattr(d, "ROOT", tmp_path)
    (tmp_path / "prompts").mkdir()
    for name in ("discovery-protocol.md", "editorial-protocol.md"):
        (tmp_path / "prompts" / name).write_text("Protocol")
    (tmp_path / "reader-profile.md").write_text("A curious reader")
    config = tmp_path / "config.toml"
    config.write_text(
        f'[general]\nvault_path="{tmp_path / "vault"}"\noutput_dir="reports"\n[reader]\nprofile="reader-profile.md"\n'
    )
    return config


def test_preview_and_live_idempotence(tmp_path, monkeypatch):
    config = setup_root(tmp_path, monkeypatch)
    calls = []

    def fake_stage(cli, stage, settings, payload, protocol, run_dir):
        calls.append((stage, payload))
        return ({"candidates": []} if stage == "research" else edition()), {
            "attempts": 1
        }

    monkeypatch.setattr(d, "run_stage", fake_stage)
    preview = d.run(config, "2026-09-06", preview=True)
    assert preview["status"] == "preview"
    assert not (tmp_path / "vault").exists()
    assert not (tmp_path / "state").exists()
    result = d.run(config, "2026-09-06")
    assert result["published"]
    assert d.run(config, "2026-09-06")["status"] == "skipped"
    assert len(calls) == 4
    assert "history" not in calls[0][1]
    assert "history" in calls[1][1]


def test_quiet_is_private_and_invalid_does_not_publish(tmp_path, monkeypatch):
    config = setup_root(tmp_path, monkeypatch)
    monkeypatch.setattr(
        d,
        "run_stage",
        lambda cli, stage, *args: (
            {"candidates": []} if stage == "research" else edition("quiet"),
            {},
        ),
    )
    result = d.run(config, "2026-09-06")
    assert result["status"] == "quiet" and result["file"] is None
    assert not (tmp_path / "vault").exists()
    assert d.run(config, "2026-09-06")["status"] == "skipped"


def test_metrics_failure_preserves_publication(tmp_path, monkeypatch, capsys):
    config = setup_root(tmp_path, monkeypatch)
    monkeypatch.setattr(
        d,
        "run_stage",
        lambda cli, stage, *args: (
            {"candidates": []} if stage == "research" else edition(),
            {},
        ),
    )
    original_open = d.Path.open

    def failing_metrics(path, *args, **kwargs):
        if path == tmp_path / "metrics.jsonl":
            raise OSError("disk quota for metrics")
        return original_open(path, *args, **kwargs)

    monkeypatch.setattr(d.Path, "open", failing_metrics)
    result = d.run(config, "2026-09-06")
    assert result["status"] == "published"
    assert d.Path(result["file"]).is_file()
    assert "WARN" in capsys.readouterr().err


def test_timeout_attempt_archived(tmp_path, monkeypatch):
    protocol = tmp_path / "protocol.md"
    protocol.write_text("Protocol")

    def timed_out(*args, **kwargs):
        raise subprocess.TimeoutExpired(args[0], 1)

    monkeypatch.setattr(d.subprocess, "run", timed_out)
    with pytest.raises(d.DiscoveryError, match="timed out"):
        d.run_stage(
            "claude", "research", {"timeout_seconds": 1}, {}, protocol, tmp_path
        )
    attempt = json.loads((tmp_path / "research-1.json").read_text())
    assert attempt["termination"] == "timeout"
    assert attempt["total_cost_usd"] is None
    assert attempt["duration_ms"] >= 0


@pytest.mark.parametrize(
    "change",
    [
        lambda e: e.update(kind="normal", main=None),
        lambda e: e.update(kind="briefs", main=None, briefs=[]),
        lambda e: e.update(kind="quiet"),
        lambda e: e["sources"].append(dict(e["sources"][0])),
        lambda e: e["main"].update(source_urls=["https://example.org/unknown"]),
        lambda e: e["sources"][0].update(url="file:///private/data"),
        lambda e: e["sources"][0].update(checked_at="not-a-date"),
        lambda e: e.update(briefs=[e["main"]] * 4),
        lambda e: e["main"].update(body="  "),
    ],
    ids=[
        "main-required",
        "brief-required",
        "quiet-empty",
        "unique-sources",
        "known-reference",
        "http-only",
        "source-date",
        "brief-limit",
        "nonempty-body",
    ],
)
def test_invalid_outputs_rejected(change):
    value = edition()
    change(value)
    with pytest.raises(ValueError):
        d.validate_edition(value)


def test_renderer_preserves_machine_contract_and_optional_opportunities():
    value = edition("briefs")
    value["opportunities"] = [
        dict(what="An actual deadline", url=source()["url"], expires="2026-09-20")
    ]
    d.validate_edition(value)
    text = d.render(value, "2026-09-06")
    for field in (
        "date:",
        "category: discovery",
        "topic:",
        "tags:",
        "sources: 1",
        "actionable: 1",
    ):
        assert field in text
    assert "## 機会メモ" in text and "2026-09-20" in text
    assert "## ソース" in text


def test_history_uses_recent_headings_only(tmp_path):
    (tmp_path / "2026-09-05_edge_old.md").write_text(
        "# A headline\n\nSecret body should not pass.\n## Useful heading\n"
    )
    (tmp_path / "2025-01-01_old.md").write_text("# Too old")
    (tmp_path / "2026-09-06_today.md").write_text("# Already today")
    (tmp_path / "nondated.md").write_text("# Undated")
    entries = d.recent_history(tmp_path, d.date(2026, 9, 6))
    assert len(entries) == 1
    assert "Secret" not in json.dumps(entries)
    assert "headline" in json.dumps(entries)


@pytest.mark.parametrize(
    "suffix",
    [
        '\n[tracks.old]\nname="obsolete"\n',
        "\n[research]\ntimeout_seconds=0\n",
        "\n[editorial]\nmodel=4\n",
    ],
    ids=["legacy", "invalid-limit", "invalid-model"],
)
def test_config_fails_before_network(tmp_path, monkeypatch, suffix):
    config = setup_root(tmp_path, monkeypatch)
    config.write_text(config.read_text() + suffix)
    monkeypatch.setattr(
        d, "run_stage", lambda *args: pytest.fail("Network must not start")
    )
    with pytest.raises(d.DiscoveryError):
        d.run(config, "2026-09-06", preview=True)


def test_failure_archives_metrics_without_publication(tmp_path, monkeypatch):
    config = setup_root(tmp_path, monkeypatch)

    def fail_run(args, **kwargs):
        return subprocess.CompletedProcess(
            args,
            1,
            json.dumps(
                {"is_error": True, "api_error_status": 401, "total_cost_usd": 0.02}
            ),
            "",
        )

    monkeypatch.setattr(d.subprocess, "run", fail_run)
    with pytest.raises(d.DiscoveryError):
        d.run(config, "2026-09-06")
    metrics = json.loads((tmp_path / "metrics.jsonl").read_text())
    assert metrics["final_class"] == "E_NO_REPORT"
    assert metrics["stages"]["research"]["attempts"] == 1
    assert metrics["total_cost"] == 0.02
    assert not (tmp_path / "vault").exists()


def test_run_timeout_reports_unknown_cost(tmp_path, monkeypatch):
    config = setup_root(tmp_path, monkeypatch)

    def fail_run(*args, **kwargs):
        raise subprocess.TimeoutExpired(args[0], 1)

    monkeypatch.setattr(d.subprocess, "run", fail_run)
    with pytest.raises(d.DiscoveryError):
        d.run(config, "2026-09-06")
    metrics = json.loads((tmp_path / "metrics.jsonl").read_text())
    assert metrics["stages"]["research"]["attempts"] == 1
    assert metrics["total_cost"] is None
    assert not metrics["cost_complete"]


def test_cli_missing_config_is_failure(monkeypatch, capsys, tmp_path):
    monkeypatch.setattr(
        d.sys,
        "argv",
        [
            "discovery.py",
            "run",
            "--config",
            str(tmp_path / "missing.toml"),
            "--date",
            "2026-09-06",
        ],
    )
    assert d.main() == 1
    assert json.loads(capsys.readouterr().out)["status"] == "error"
