"""dr_pipeline subcommand の単体テスト (pytest)。

旧 test-log-summary.bats が source の python をコピペしていた問題を解消し、
本テストは scripts/lib/dr_pipeline.py を直接 import して検証する (単一 parser-of-record)。
fixtures は実ログ由来 (tests/fixtures/result-401.json 等)。
"""
import io
import json
import pathlib
import sys

import pytest

import dr_pipeline

FIXTURES = pathlib.Path(__file__).parent / "fixtures"
CONFIG = str(FIXTURES / "config.toml")
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
            ["cost=$0.1234", "turns=10", "duration=60s", "tokens_in=5000", "tokens_out=1200", "searches=4"],
        ),
        (
            '{"total_cost_usd":0,"num_turns":0,"duration_ms":0,"usage":{"input_tokens":0,"output_tokens":0}}',
            ["SUMMARY Pass1:", "cost=$0.0000", "turns=0"],
        ),
        (
            '[{"type":"assistant","message":{"content":[]}},{"type":"result","total_cost_usd":0.5678,"num_turns":20,"duration_ms":120000,"usage":{"input_tokens":8000,"output_tokens":2000}}]',
            ["cost=$0.5678", "turns=20", "duration=120s", "tokens_in=8000", "tokens_out=2000"],
        ),
        ('[{"type":"assistant","message":{"content":[]}}]', ["cost=$0.0000"]),
        ('[]', ["SUMMARY Pass1:", "cost=$0.0000"]),
        ('{}', ["SUMMARY Pass1:", "cost=$0.0000", "turns=0"]),
    ],
    ids=["dict", "zero-cost", "array-with-result", "array-no-result", "empty-array", "missing-fields"],
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


# === total-summary ===

@pytest.mark.unit
def test_total_summary_dict_dict(monkeypatch, capsys):
    stdin = '{"total_cost_usd":0.25,"duration_ms":60000}\n{"total_cost_usd":0.50,"duration_ms":120000}\n'
    rc, out, _ = run_cmd(monkeypatch, capsys, ["total-summary"], stdin)
    assert rc == 0
    assert "cost=$0.7500" in out
    assert "duration=180s" in out
    assert "Pass1: $0.2500" in out
    assert "Pass2: $0.5000" in out


@pytest.mark.unit
def test_total_summary_dict_array(monkeypatch, capsys):
    stdin = (
        '{"total_cost_usd":0.25,"duration_ms":60000}\n'
        '[{"type":"assistant","message":{"content":[]}},{"type":"result","total_cost_usd":0.50,"duration_ms":120000}]\n'
    )
    rc, out, _ = run_cmd(monkeypatch, capsys, ["total-summary"], stdin)
    assert rc == 0
    assert "parse error" not in out
    assert "cost=$0.7500" in out
    assert "Pass2: $0.5000" in out


@pytest.mark.unit
def test_total_summary_missing_second_line_reports_parse_error(monkeypatch, capsys):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["total-summary"], '{"total_cost_usd":0.25}\n')
    assert "parse error" in out


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
        ('not-json', "\tparse-fail"),
        # 空入力は `'' or 'null'` で null パースされ {} → "\tfalse" (parse-fail ではない)
        ('', "\tfalse"),
    ],
    ids=["clean", "auth-401", "garbage", "empty"],
)
def test_error_fields_cases(monkeypatch, capsys, stdin, expected):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["error-fields"], stdin)
    assert rc == 0
    assert out.strip() == expected.strip()


# === parse-stream ===

@pytest.mark.unit
def test_parse_stream_normal_aggregates_tool_counts(monkeypatch, capsys):
    stdin = (FIXTURES / "stream-normal.ndjson").read_text()
    rc, out, _ = run_cmd(monkeypatch, capsys, ["parse-stream"], stdin)
    assert rc == 0
    d = json.loads(out)
    assert d["type"] == "result"
    assert d["tool_counts"] == {"WebSearch": 1, "WebFetch": 1}


@pytest.mark.unit
def test_parse_stream_no_result_event_errors(monkeypatch, capsys):
    stdin = (FIXTURES / "stream-no-result.ndjson").read_text()
    rc, out, err = run_cmd(monkeypatch, capsys, ["parse-stream"], stdin)
    assert rc == 1
    assert "No result event found" in err


@pytest.mark.unit
def test_parse_stream_skips_unparseable_lines(monkeypatch, capsys):
    stdin = 'garbage line\n{"type":"result","total_cost_usd":1.0}\n'
    rc, out, _ = run_cmd(monkeypatch, capsys, ["parse-stream"], stdin)
    assert rc == 0
    assert json.loads(out)["total_cost_usd"] == 1.0


# === validate-theme ===

def _valid_themes():
    return json.dumps({
        "themes": [
            {"track": "authorship", "topic": "T", "slug": "a-slug", "score": 80, "rationale": "r", "reinforces": ["concept/x"]},
            {"track": "contemplative", "topic": "T", "slug": "b-slug", "score": 80, "rationale": "r", "reinforces": ["concept/y"]},
            {"track": "akc", "topic": "T", "slug": "c-slug", "score": 80, "rationale": "r", "reinforces": ["concept/z"]},
        ]
    })


@pytest.mark.unit
def test_validate_theme_valid(monkeypatch, capsys):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["validate-theme", CONFIG], _valid_themes())
    assert rc == 0
    assert json.loads(out)["themes"][0]["track"] == "authorship"


@pytest.mark.unit
def test_validate_theme_strips_code_fence(monkeypatch, capsys):
    stdin = "```json\n" + _valid_themes() + "\n```"
    rc, out, _ = run_cmd(monkeypatch, capsys, ["validate-theme", CONFIG], stdin)
    assert rc == 0
    assert "themes" in json.loads(out)


@pytest.mark.unit
@pytest.mark.parametrize(
    "mutate,reason",
    [
        (lambda d: d["themes"].pop(), "wrong-count"),
        (lambda d: d["themes"][0].__setitem__("track", "bogus"), "invalid-track"),
        (lambda d: d["themes"][0].__setitem__("slug", "Bad Slug!"), "invalid-slug"),
        (lambda d: d["themes"][0].pop("rationale"), "missing-key"),
        (lambda d: d["themes"][0].__setitem__("topic", "x" * 201), "topic-too-long"),
        (lambda d: d["themes"][0].__setitem__("rationale", "x" * 501), "rationale-too-long"),
        (lambda d: d["themes"][0].pop("reinforces"), "missing-reinforces"),
        (lambda d: d["themes"][0].__setitem__("reinforces", []), "empty-reinforces"),
        (lambda d: d["themes"][0].__setitem__("reinforces", ['bad "quote"']), "reinforces-bad-char"),
        (lambda d: d["themes"][0].__setitem__("reinforces", [123]), "reinforces-non-string"),
    ],
    ids=["wrong-count", "invalid-track", "invalid-slug", "missing-key", "topic-too-long",
         "rationale-too-long", "missing-reinforces", "empty-reinforces", "reinforces-bad-char", "reinforces-non-string"],
)
def test_validate_theme_rejects(monkeypatch, capsys, mutate, reason):
    d = json.loads(_valid_themes())
    mutate(d)
    rc, out, err = run_cmd(monkeypatch, capsys, ["validate-theme", CONFIG], json.dumps(d))
    assert rc == 1


@pytest.mark.unit
def test_validate_theme_no_tracks_config_errors(monkeypatch, capsys):
    rc, out, err = run_cmd(monkeypatch, capsys, ["validate-theme", CONFIG_NO_TRACKS], _valid_themes())
    assert rc == 1
    assert "No tracks defined" in err


@pytest.mark.unit
def test_validate_theme_no_json_object_errors(monkeypatch, capsys):
    rc, out, err = run_cmd(monkeypatch, capsys, ["validate-theme", CONFIG], "no braces here")
    assert rc == 1
    assert "No JSON object found" in err


@pytest.mark.unit
def test_validate_theme_malformed_json_in_braces_errors(monkeypatch, capsys):
    # 波括弧はあるが JSON として壊れている → JSONDecodeError 経路
    rc, out, err = run_cmd(monkeypatch, capsys, ["validate-theme", CONFIG], "{themes: [unquoted]}")
    assert rc == 1
    assert "JSON parse error" in err


# === result-field ===

@pytest.mark.unit
def test_result_field_extracts_result(monkeypatch, capsys):
    stdin = '{"type":"result","result":"the theme json string"}'
    rc, out, _ = run_cmd(monkeypatch, capsys, ["result-field"], stdin)
    assert rc == 0
    assert out.strip() == "the theme json string"


@pytest.mark.unit
def test_result_field_missing_is_empty(monkeypatch, capsys):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["result-field"], '{"type":"result"}')
    assert rc == 0
    assert out.strip() == ""


# === vault-path ===

@pytest.mark.unit
def test_vault_path_reads_general(monkeypatch, capsys):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["vault-path", CONFIG])
    assert rc == 0
    assert out.strip() == "/tmp/fixture-vault"


@pytest.mark.unit
def test_vault_path_missing_is_empty(monkeypatch, capsys):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["vault-path", CONFIG_NO_TRACKS])
    assert rc == 0
    assert out.strip() == "/tmp/fixture-vault"  # no-tracks config も general は持つ


# === themes-log ===

@pytest.mark.unit
def test_themes_log(monkeypatch, capsys):
    arg = json.dumps({"themes": [{"track": "akc", "topic": "Hello"}]})
    rc, out, _ = run_cmd(monkeypatch, capsys, ["themes-log", arg])
    assert rc == 0
    assert out.strip() == 'Pass 1 themes: akc="Hello"'


# === tracks ===

@pytest.mark.unit
def test_tracks_emits_tsv(monkeypatch, capsys):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["tracks", CONFIG])
    assert rc == 0
    lines = [ln for ln in out.splitlines() if ln]
    assert len(lines) == 3
    assert "authorship\t/tmp/fixture-repos/authorship-strategy" in lines


# === past-themes ===

@pytest.mark.unit
def test_past_themes_groups_by_track(monkeypatch, capsys, tmp_path):
    past = tmp_path / "past_topics.json"
    past.write_text(json.dumps({"topics": [
        {"track": "akc", "title": "Old AKC topic", "date": "2026-06-01"},
        {"track": "authorship", "title": "Old authorship topic", "date": "2026-06-02"},
        {"track": "unknown-track", "title": "should be filtered", "date": "2026-06-03"},
    ]}))
    rc, out, _ = run_cmd(monkeypatch, capsys, ["past-themes", str(past), CONFIG])
    assert rc == 0
    assert "Track: akc" in out
    assert "Old AKC topic" in out
    assert "should be filtered" not in out  # 未定義 track は除外


@pytest.mark.unit
def test_past_themes_missing_file_is_empty(monkeypatch, capsys, tmp_path):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["past-themes", str(tmp_path / "nope.json"), CONFIG])
    assert rc == 0
    assert "過去テーマ履歴" in out


# === graph-health ===

@pytest.mark.unit
def test_graph_health_valid(monkeypatch, capsys, tmp_path):
    g = tmp_path / "graph.jsonld"
    g.write_text('{"@graph": []}')
    rc, _, _ = run_cmd(monkeypatch, capsys, ["graph-health", str(g)])
    assert rc == 0


@pytest.mark.unit
def test_graph_health_missing(monkeypatch, capsys, tmp_path):
    rc, _, err = run_cmd(monkeypatch, capsys, ["graph-health", str(tmp_path / "nope.jsonld")])
    assert rc == 2
    assert "not found" in err


@pytest.mark.unit
def test_graph_health_bad_json(monkeypatch, capsys, tmp_path):
    g = tmp_path / "broken.jsonld"
    g.write_text("{not valid")
    rc, _, err = run_cmd(monkeypatch, capsys, ["graph-health", str(g)])
    assert rc == 3
    assert "parse error" in err


@pytest.mark.unit
def test_graph_health_schema_invalid_missing_graph_key(monkeypatch, capsys, tmp_path):
    g = tmp_path / "noatgraph.jsonld"
    g.write_text('{"@context": {}}')  # valid JSON だが @graph が無い
    rc, _, err = run_cmd(monkeypatch, capsys, ["graph-health", str(g)])
    assert rc == 4
    assert "@graph" in err


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
