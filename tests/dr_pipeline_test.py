"""dr_pipeline subcommand の単体テスト (pytest)。

旧 test-log-summary.bats が source の python をコピペしていた問題を解消し、
本テストは scripts/lib/dr_pipeline.py を直接 import して検証する (単一 parser-of-record)。
fixtures は実ログ由来 (tests/fixtures/result-401.json 等)。
"""

import io
import json
import pathlib
import sys

import dr_pipeline
import pytest

FIXTURES = pathlib.Path(__file__).parent / "fixtures"
CONFIG = str(FIXTURES / "config-lines.toml")
CONFIG_NO_TRACKS = str(FIXTURES / "config-no-tracks.toml")


def run_cmd(monkeypatch, capsys, args, stdin=""):
    """dr_pipeline.main(args) を stdin 差し替えで実行し (rc, stdout, stderr) を返す。"""
    monkeypatch.setattr(sys, "stdin", io.StringIO(stdin))
    rc = dr_pipeline.main(args)
    out, err = capsys.readouterr()
    return rc, out, err


# === log-summary ===


@pytest.mark.unit
@pytest.mark.parametrize(
    "stdin,expect",
    [
        (
            '{"total_cost_usd":0.1234,"num_turns":10,"duration_ms":60000,"usage":{"input_tokens":5000,"output_tokens":1200},"tool_counts":{"WebSearch":3,"WebFetch":1}}',
            [
                "cost=$0.1234",
                "turns=10",
                "duration=60s",
                "tokens_in=5000",
                "tokens_out=1200",
                "searches=4",
            ],
        ),
        (
            '{"total_cost_usd":0,"num_turns":0,"duration_ms":0,"usage":{"input_tokens":0,"output_tokens":0}}',
            ["SUMMARY Pass1:", "cost=$0.0000", "turns=0"],
        ),
        (
            '[{"type":"assistant","message":{"content":[]}},{"type":"result","total_cost_usd":0.5678,"num_turns":20,"duration_ms":120000,"usage":{"input_tokens":8000,"output_tokens":2000}}]',
            [
                "cost=$0.5678",
                "turns=20",
                "duration=120s",
                "tokens_in=8000",
                "tokens_out=2000",
            ],
        ),
        ('[{"type":"assistant","message":{"content":[]}}]', ["cost=$0.0000"]),
        ("[]", ["SUMMARY Pass1:", "cost=$0.0000"]),
        ("{}", ["SUMMARY Pass1:", "cost=$0.0000", "turns=0"]),
    ],
    ids=[
        "dict",
        "zero-cost",
        "array-with-result",
        "array-no-result",
        "empty-array",
        "missing-fields",
    ],
)
def test_log_summary_ok(monkeypatch, capsys, stdin, expect):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["log-summary", "Pass1"], stdin)
    assert rc == 0
    assert "parse error" not in out
    for fragment in expect:
        assert fragment in out


@pytest.mark.unit
def test_log_summary_invalid_json_reports_parse_error(monkeypatch, capsys):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["log-summary", "Err"], "not-json")
    assert rc == 0
    assert "parse error" in out


@pytest.mark.unit
def test_log_summary_no_searches_omits_tool_str(monkeypatch, capsys):
    stdin = '{"total_cost_usd":0.01,"num_turns":1,"duration_ms":1000,"usage":{"input_tokens":1,"output_tokens":1}}'
    rc, out, _ = run_cmd(monkeypatch, capsys, ["log-summary", "Pass2"], stdin)
    assert rc == 0
    assert "searches=" not in out


# === error-fields (auth/401 判定) ===


@pytest.mark.unit
def test_error_fields_401_fixture(monkeypatch, capsys):
    stdin = (FIXTURES / "result-401.json").read_text()
    rc, out, _ = run_cmd(monkeypatch, capsys, ["error-fields"], stdin)
    assert rc == 0
    assert out.strip() == "401\ttrue"


@pytest.mark.unit
def test_error_fields_success_fixture(monkeypatch, capsys):
    stdin = (FIXTURES / "result-success.json").read_text()
    rc, out, _ = run_cmd(monkeypatch, capsys, ["error-fields"], stdin)
    assert rc == 0
    # is_error は false。api_error_status は 401 ではない
    code, is_err = out.rstrip("\n").split("\t")
    assert is_err == "false"
    assert code != "401"


@pytest.mark.unit
@pytest.mark.parametrize(
    "stdin,expected",
    [
        ('{"is_error":false,"api_error_status":null}', "\tfalse"),
        ('{"is_error":true,"api_error_status":401}', "401\ttrue"),
        ("not-json", "\tparse-fail"),
        # 空入力は `'' or 'null'` で null パースされ {} → "\tfalse" (parse-fail ではない)
        ("", "\tfalse"),
    ],
    ids=["clean", "auth-401", "garbage", "empty"],
)
def test_error_fields_cases(monkeypatch, capsys, stdin, expected):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["error-fields"], stdin)
    assert rc == 0
    assert out.strip() == expected.strip()


# === vault-path ===


@pytest.mark.unit
def test_vault_path_reads_general(monkeypatch, capsys):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["vault-path", CONFIG])
    assert rc == 0
    assert out.strip() == "/nonexistent/fixture-vault"


@pytest.mark.unit
def test_vault_path_missing_is_empty(monkeypatch, capsys):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["vault-path", CONFIG_NO_TRACKS])
    assert rc == 0
    assert (
        out.strip() == "/nonexistent/fixture-vault"
    )  # no-tracks config も general は持つ


# === report-dir ===


@pytest.mark.unit
def test_report_dir_joins_vault_and_output(monkeypatch, capsys):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["report-dir", CONFIG])
    assert rc == 0
    assert out.strip() == "/nonexistent/fixture-vault/daily-research"


@pytest.mark.unit
def test_report_dir_missing_output_dir_is_empty(monkeypatch, capsys):
    # output_dir 欠落時は空文字 → 呼び出し側 (ctl-015) はゲートを skip する
    rc, out, _ = run_cmd(monkeypatch, capsys, ["report-dir", CONFIG_NO_TRACKS])
    assert rc == 0
    assert out.strip() == ""


# === tracks ===


@pytest.mark.unit
def test_tracks_emits_line_repo_tsv(monkeypatch, capsys):
    # 1 repo 1 行 (4 line = 4 repo, ADR-0008)。
    rc, out, _ = run_cmd(monkeypatch, capsys, ["tracks", CONFIG])
    assert rc == 0
    lines = [ln for ln in out.splitlines() if ln]
    assert len(lines) == 4
    assert "akc\takc\t/nonexistent/fixture-repos/agent-knowledge-cycle" in lines
    assert (
        "contemplative\tcontemplative\t/nonexistent/fixture-repos/contemplative-agent"
        in lines
    )
    assert "aap\taap\t/nonexistent/fixture-repos/agent-attribution-practice" in lines
    assert (
        "authorship\tauthorship\t/nonexistent/fixture-repos/authorship-strategy"
        in lines
    )


@pytest.mark.unit
def test_tracks_old_schema_config_errors(monkeypatch, capsys):
    rc, _, err = run_cmd(
        monkeypatch, capsys, ["tracks", str(FIXTURES / "config-old-schema.toml")]
    )
    assert rc == 1
    assert "legacy schema" in err


# === past-themes ===


@pytest.mark.unit
def test_past_themes_groups_aliases_into_line(monkeypatch, capsys, tmp_path):
    # 旧 track 名 (aliases) の履歴が新 line 配下に集約され dedup 文脈が継続する
    past = tmp_path / "past_topics.json"
    past.write_text(
        json.dumps(
            {
                "topics": [
                    {"track": "akc", "title": "Old AKC topic", "date": "2026-06-01"},
                    {
                        "track": "agent_cognition",
                        "title": "Old cognition topic",
                        "date": "2026-06-02",
                    },
                    {"track": "aap", "title": "Old AAP topic", "date": "2026-06-03"},
                    {
                        "track": "ai_dev",
                        "title": "Old ai_dev topic",
                        "date": "2026-06-04",
                    },
                    {
                        "track": "unknown-track",
                        "title": "should be filtered",
                        "date": "2026-06-05",
                    },
                    {
                        "track": "attribution",
                        "title": "Old attribution line should stay historical",
                        "date": "2026-07-08",
                    },
                ]
            }
        )
    )
    rc, out, _ = run_cmd(monkeypatch, capsys, ["past-themes", str(past), CONFIG])
    assert rc == 0
    assert "Track: akc (旧 track: agent_systems, agent_cognition を含む)" in out
    assert "Old cognition topic" in out
    assert "Old AAP topic" in out
    assert "Old AKC topic" in out
    assert "Track: contemplative" in out
    assert "Old ai_dev topic" in out  # contemplative の alias ai_dev も集約
    assert "Track: authorship" not in out  # 履歴が無い line は表示しない
    assert "should be filtered" not in out  # 未定義 track は除外


@pytest.mark.unit
def test_past_themes_missing_file_is_empty(monkeypatch, capsys, tmp_path):
    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["past-themes", str(tmp_path / "nope.json"), CONFIG]
    )
    assert rc == 0
    assert "過去テーマ履歴" in out


# === line-brief (ADR-0008 per-repo 実行) ===


@pytest.mark.unit
def test_line_brief_emits_line_definition(monkeypatch, capsys):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["line-brief", CONFIG, "akc"])
    assert rc == 0
    assert "name: AKC Line" in out
    assert "focus: AKC line focus" in out
    assert "実行可能性 (weight 45)" in out
    assert "fixture-source-a" in out
    assert ".notes/TASKS.md" in out
    assert "github.com/example-author" in out  # self_signals (自己汚染ガード)


@pytest.mark.unit
def test_line_brief_unknown_track_errors(monkeypatch, capsys):
    rc, _, err = run_cmd(monkeypatch, capsys, ["line-brief", CONFIG, "nope"])
    assert rc == 1
    assert "unknown track" in err


# === metrics-append / metrics-backfill (ADR-0006, per-repo 集約は ADR-0008) ===

RUN1_JSON = '{"total_cost_usd":2.5,"num_turns":16,"duration_ms":255000,"usage":{"input_tokens":1480,"output_tokens":11101},"tool_counts":{"WebSearch":15,"WebFetch":2}}'
RUN2_JSON = '{"total_cost_usd":7.5,"num_turns":10,"duration_ms":99000,"usage":{"input_tokens":20,"output_tokens":8719}}'


@pytest.mark.unit
def test_metrics_append_aggregates_runs_into_pass2(monkeypatch, capsys, tmp_path):
    # per-repo 実行 (ADR-0008): N run JSON + lint JSON を stdin で受け、
    # run 群を pass2 に合算・pass1 は None (旧レコード形との互換写像)。
    metrics = tmp_path / "metrics.jsonl"
    lint = '{"date":"2026-08-05","files":4,"hard_fail":0,"soft_fail":1,"results":[]}'
    rc, out, _ = run_cmd(
        monkeypatch,
        capsys,
        ["metrics-append", str(metrics), "2026-08-05", "OK", "4", "1"],
        f"{RUN1_JSON}\n{RUN2_JSON}\n{lint}",
    )
    assert rc == 0
    assert "2 runs" in out
    rec = json.loads(metrics.read_text())
    assert rec["date"] == "2026-08-05"
    assert rec["final_class"] == "OK"
    assert rec["report_count"] == 4
    assert rec["fallback_used"] is True  # retry フラグを旧フィールド名に記録
    assert rec["pass1"] is None
    assert rec["pass2"]["turns"] == 26
    assert rec["pass2"]["cost"] == 10.0
    assert rec["pass2"]["searches"] == 17
    assert rec["lint"]["soft_fail"] == 1
    assert rec["total_cost"] == 10.0


@pytest.mark.unit
def test_metrics_append_tolerates_empty_stdin_lines(monkeypatch, capsys, tmp_path):
    metrics = tmp_path / "metrics.jsonl"
    rc, _, _ = run_cmd(
        monkeypatch,
        capsys,
        ["metrics-append", str(metrics), "2026-08-05", "E_NO_REPORT", "0", "0"],
        "\n\n\n",
    )
    assert rc == 0
    rec = json.loads(metrics.read_text())
    assert rec["pass1"] is None and rec["pass2"] is None and rec["lint"] is None
    assert rec["total_cost"] == 0
    assert rec["fallback_used"] is False


BACKFILL_LOG = """\
[2026-07-29 05:00:00] === Starting daily research ===
[2026-07-29 05:04:34] SUMMARY Pass1: cost=$2.7483 turns=16 duration=255s tokens_in=1480 tokens_out=11101 searches=17
[2026-07-29 05:04:34] === Fallback: Sonnet handles theme selection + research ===
[2026-07-29 05:05:53] SUMMARY Pass2: cost=$0.8994 turns=13 duration=77s tokens_in=4127 tokens_out=5350
[2026-07-29 05:05:53] === Completed successfully ===
[2026-07-29 05:58:28] === Starting daily research ===
[2026-07-29 06:01:38] SUMMARY Pass1: cost=$2.1473 turns=15 duration=177s tokens_in=2922 tokens_out=8464 searches=10
[2026-07-29 06:11:32] SUMMARY Pass2: cost=$7.5734 turns=10 duration=99s tokens_in=20 tokens_out=8719
[2026-07-29 06:11:32] Report existence gate passed: 4 report(s) for 2026-07-29
[2026-07-29 06:11:32] === Failed (E_NO_REPORT, exit code 0) ===
"""

BACKFILL_LOG_PER_REPO = """\
[2026-08-05 05:00:00] === Starting daily research ===
[2026-08-05 05:10:00] SUMMARY Run(akc): cost=$1.0000 turns=10 duration=100s tokens_in=100 tokens_out=200 searches=5
[2026-08-05 05:20:00] SUMMARY Run(authorship): cost=$2.0000 turns=20 duration=200s tokens_in=300 tokens_out=400 searches=7
[2026-08-05 05:20:00] Report existence gate passed: 4 report(s) for 2026-08-05
[2026-08-05 05:20:00] === Completed successfully ===
"""


@pytest.mark.unit
def test_metrics_backfill_parses_runs_and_dedupes(monkeypatch, capsys, tmp_path):
    logs = tmp_path / "logs"
    logs.mkdir()
    (logs / "2026-07-29.log").write_text(BACKFILL_LOG)
    (logs / "launchd-stderr.log").write_text("noise")  # 日付形式でないログは無視
    metrics = tmp_path / "metrics.jsonl"

    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["metrics-backfill", str(metrics), str(logs)]
    )
    assert rc == 0
    assert "backfilled 2 run(s)" in out
    recs = [json.loads(x) for x in metrics.read_text().splitlines()]
    assert recs[0]["fallback_used"] is True
    assert recs[0]["final_class"] == "OK"
    assert recs[0]["pass1"]["searches"] == 17
    assert recs[1]["fallback_used"] is False
    assert recs[1]["report_count"] == 4
    assert recs[1]["final_class"] == "E_NO_REPORT"
    assert recs[1]["total_cost"] == pytest.approx(9.7207)

    # 再実行しても重複しない (冪等)
    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["metrics-backfill", str(metrics), str(logs)]
    )
    assert "backfilled 0 run(s)" in out
    assert len(metrics.read_text().splitlines()) == 2


@pytest.mark.unit
def test_metrics_backfill_aggregates_per_repo_run_lines(monkeypatch, capsys, tmp_path):
    # per-repo 形式 (SUMMARY Run(<track>):) は pass2 に合算される (ADR-0008)
    logs = tmp_path / "logs"
    logs.mkdir()
    (logs / "2026-08-05.log").write_text(BACKFILL_LOG_PER_REPO)
    metrics = tmp_path / "metrics.jsonl"

    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["metrics-backfill", str(metrics), str(logs)]
    )
    assert rc == 0
    assert "backfilled 1 run(s)" in out
    rec = json.loads(metrics.read_text())
    assert rec["pass1"] is None
    assert rec["pass2"]["turns"] == 30
    assert rec["pass2"]["cost"] == 3.0
    assert rec["pass2"]["searches"] == 12
    assert rec["report_count"] == 4
    assert rec["final_class"] == "OK"
    assert rec["total_cost"] == 3.0


# === report-lint (ctl-016, ADR-0009 自由形式 + 固定 2 節) ===

GOOD_REPORT = (
    "---\ndate: 2026-08-05\nactionable: 1\n---\n\n# T\n\n"
    "冒頭の結論と背景解説を含む自由形式の本文。\n\n"
    "## 機会メモ\n- **何を**: x\n- **どこで**: y\n- **失効日**: 2026-08-29\n\n"
    "## ソース\n"
    + "\n".join(f"- [s{i}](https://example.com/{i})" for i in range(5))
    + "\n"
    + "p" * 1600
)


def _lint_args(report_dir, date="2026-08-05"):
    return ["report-lint", str(report_dir), date, CONFIG]


@pytest.mark.unit
def test_report_lint_all_pass(monkeypatch, capsys, tmp_path):
    (tmp_path / "2026-08-05_akc_good.md").write_text(GOOD_REPORT)
    (tmp_path / "2026-08-04_akc_other-day.md").write_text("ignored")
    rc, out, _ = run_cmd(monkeypatch, capsys, _lint_args(tmp_path))
    assert rc == 0
    d = json.loads(out)
    assert d["files"] == 1 and d["hard_fail"] == 0 and d["soft_fail"] == 0


@pytest.mark.unit
def test_report_lint_hard_fail_no_sources(monkeypatch, capsys, tmp_path):
    (tmp_path / "2026-08-05_akc_bad.md").write_text("# T\n\n本文だけ")
    rc, out, _ = run_cmd(monkeypatch, capsys, _lint_args(tmp_path))
    assert rc == 2
    d = json.loads(out)
    assert d["hard_fail"] == 1
    hard = d["results"][0]["hard"]
    assert any("ソース節" in h for h in hard)
    assert any("0 件" in h for h in hard)


@pytest.mark.unit
def test_report_lint_soft_violations(monkeypatch, capsys, tmp_path):
    # ソース節 + URL 2 件はあるが、必須節と本文長が不足 → soft のみ (exit 0)
    text = "# T\n\n## ソース\n- [a](https://a.com)\n- [b](https://b.com)\n"
    (tmp_path / "2026-08-05_akc_thin.md").write_text(text)
    rc, out, _ = run_cmd(monkeypatch, capsys, _lint_args(tmp_path))
    assert rc == 0
    soft = json.loads(out)["results"][0]["soft"]
    assert any("出典 URL 2 件" in s for s in soft)
    assert any("必須節欠落" in s for s in soft)
    assert any("機会メモ" in s for s in soft)
    assert any("本文" in s for s in soft)


# === wiki-quality-scan ===


@pytest.mark.unit
def test_wiki_quality_scan_attributes_lines(monkeypatch, capsys, tmp_path):
    import datetime

    today = datetime.date.today().isoformat()
    concept = tmp_path / "wiki" / "concept"
    concept.mkdir(parents=True)
    (concept / "概念A.md").write_text(
        f"通常の段落。\n\n"
        f"FLAGGED（一次照合待ち）: 数値クレーム（出典: [[{today}_agent_systems_topic-a]]）。\n\n"
        f"- 本ページの数値は一次未照合のため推定として扱う（出典: [[{today}_tech_topic-b]]）。\n\n"
        f"古い注記 FLAGGED [[2020-01-01_tech_ancient-topic]]\n"
    )
    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["wiki-quality-scan", str(tmp_path), "30", CONFIG]
    )
    assert rc == 0
    d = json.loads(out)
    assert d["flagged_reports"] == 2  # 30 日 cutoff で 2020 年分は除外
    assert d["by_line"] == {"agent_systems": 1, "tech": 1}
    assert d["reports"][f"{today}_agent_systems_topic-a"] == ["概念A"]


@pytest.mark.unit
def test_wiki_quality_scan_missing_dir(monkeypatch, capsys, tmp_path):
    rc, _, err = run_cmd(monkeypatch, capsys, ["wiki-quality-scan", str(tmp_path)])
    assert rc == 1
    assert "not found" in err


# === review-age ===


@pytest.mark.unit
def test_review_age_never_and_days(monkeypatch, capsys, tmp_path):
    import datetime

    state = tmp_path / "dr-review-state.json"
    rc, out, _ = run_cmd(monkeypatch, capsys, ["review-age", str(state)])
    assert rc == 0 and out.strip() == "never"

    state.write_text(json.dumps({"last_review": datetime.date.today().isoformat()}))
    rc, out, _ = run_cmd(monkeypatch, capsys, ["review-age", str(state)])
    assert rc == 0 and out.strip() == "0"


# === expect-check (DR-Expect) ===


@pytest.mark.unit
def test_expect_check_verdicts(monkeypatch, capsys, tmp_path):
    metrics = tmp_path / "metrics.jsonl"
    recs = [
        {
            "date": f"2026-07-2{i}",
            "final_class": "OK",
            "report_count": 4,
            "fallback_used": i == 5,
            "pass1": {"turns": 10 + i, "cost": 2.0},
            "pass2": {"turns": 10, "cost": 5.0},
            "total_cost": 7.0,
            "lint": {"hard_fail": 0},
        }
        for i in range(5, 9)  # 2026-07-25 .. 2026-07-28
    ]
    metrics.write_text("\n".join(json.dumps(r) for r in recs) + "\n")
    stdin = (
        "2026-07-24\tpass1_turns_max <= 18\n"
        "2026-07-24\tpass1_turns_max <= 17\n"
        "2026-07-24\tfallback_rate <= 0.25\n"
        "2026-07-28\tno_report_count == 0\n"
        "2026-07-30\tpass1_turns_p90 <= 20\n"
        "2026-07-24\tgarbage line\n"
    )
    rc, out, _ = run_cmd(monkeypatch, capsys, ["expect-check", str(metrics)], stdin)
    assert rc == 0
    lines = out.strip().splitlines()
    assert lines[0].startswith("ACHIEVED\t")  # max turns = 18 <= 18
    assert lines[1].startswith("NOT_ACHIEVED\t")
    assert lines[2].startswith("ACHIEVED\t")  # 1/4 = 0.25
    assert lines[3].startswith("ACHIEVED\t")  # 07-28 より後は 0 record でも count=0
    assert lines[4].startswith("INSUFFICIENT_DATA\t")
    assert lines[5].startswith("INVALID\t")


# === dispatcher ===


@pytest.mark.unit
def test_unknown_subcommand_usage(monkeypatch, capsys):
    rc, _, err = run_cmd(monkeypatch, capsys, ["bogus-cmd"])
    assert rc == 64
    assert "usage:" in err


@pytest.mark.unit
def test_no_subcommand_usage(monkeypatch, capsys):
    rc, _, err = run_cmd(monkeypatch, capsys, [])
    assert rc == 64
