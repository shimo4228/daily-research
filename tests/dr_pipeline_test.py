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
    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["total-summary"], '{"total_cost_usd":0.25}\n'
    )
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
    # fixture config の 4 line 構成に対応。
    # repo-backed の coverage と、3 本の explore をカバーする。
    return json.dumps(
        {
            "themes": [
                {
                    "track": "agent_systems",
                    "repos": ["akc", "contemplative", "aap"],
                    "mode": "coverage",
                    "topic": "T",
                    "slug": "a-slug",
                    "score": 80,
                    "rationale": "r",
                    "reinforces": ["concept/x"],
                },
                {
                    "track": "human_ai_publics",
                    "repos": [],
                    "mode": "explore",
                    "topic": "T",
                    "slug": "b-slug",
                    "score": 80,
                    "rationale": "r",
                },
                {
                    "track": "tech",
                    "repos": [],
                    "mode": "explore",
                    "topic": "T",
                    "slug": "c-slug",
                    "score": 80,
                    "rationale": "r",
                    "reinforces": [],
                },
                {
                    "track": "software_paradigms",
                    "repos": [],
                    "mode": "explore",
                    "topic": "T",
                    "slug": "d-slug",
                    "score": 80,
                    "rationale": "r",
                },
            ]
        }
    )


@pytest.mark.unit
def test_validate_theme_valid(monkeypatch, capsys):
    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["validate-theme", CONFIG], _valid_themes()
    )
    assert rc == 0
    assert json.loads(out)["themes"][0]["track"] == "agent_systems"


@pytest.mark.unit
@pytest.mark.parametrize("old_track", ["attribution", "agent_cognition"])
def test_validate_theme_rejects_retired_line_keys(monkeypatch, capsys, old_track):
    data = json.loads(_valid_themes())
    data["themes"][0]["track"] = old_track
    rc, _, err = run_cmd(
        monkeypatch, capsys, ["validate-theme", CONFIG], json.dumps(data)
    )
    assert rc == 1
    assert "invalid track" in err


@pytest.mark.unit
def test_validate_theme_strips_code_fence(monkeypatch, capsys):
    stdin = "```json\n" + _valid_themes() + "\n```"
    rc, out, _ = run_cmd(monkeypatch, capsys, ["validate-theme", CONFIG], stdin)
    assert rc == 0
    assert "themes" in json.loads(out)


@pytest.mark.unit
def test_validate_theme_normalizes_defaults(monkeypatch, capsys):
    # mode / repos / 関係フィールド省略時の default 正規化 (repo line → coverage、
    # 自由探索 line → explore) を検証。Pass 2 が graph に記録するため書き戻しが必要。
    d = json.loads(_valid_themes())
    del d["themes"][0]["mode"]  # repo line → coverage に正規化
    del d["themes"][1]["mode"]  # 自由探索 line → explore に正規化
    del d["themes"][1]["repos"]  # 省略 → [] に正規化
    rc, out, _ = run_cmd(monkeypatch, capsys, ["validate-theme", CONFIG], json.dumps(d))
    assert rc == 0
    themes = json.loads(out)["themes"]
    assert themes[0]["mode"] == "coverage"
    assert themes[1]["mode"] == "explore"
    assert themes[1]["repos"] == []
    assert themes[1]["reinforces"] == []
    assert themes[1]["challenges"] == []


@pytest.mark.unit
def test_validate_theme_old_schema_config_errors(monkeypatch, capsys):
    rc, _, err = run_cmd(
        monkeypatch,
        capsys,
        ["validate-theme", str(FIXTURES / "config-old-schema.toml")],
        _valid_themes(),
    )
    assert rc == 1
    assert "legacy schema" in err


@pytest.mark.unit
@pytest.mark.parametrize(
    "mutate,reason",
    [
        (lambda d: d["themes"].pop(), "wrong-count"),
        (lambda d: d["themes"][0].__setitem__("track", "bogus"), "invalid-track"),
        (lambda d: d["themes"][0].__setitem__("slug", "Bad Slug!"), "invalid-slug"),
        (lambda d: d["themes"][0].pop("rationale"), "missing-key"),
        (lambda d: d["themes"][0].__setitem__("topic", "x" * 201), "topic-too-long"),
        (
            lambda d: d["themes"][0].__setitem__("rationale", "x" * 501),
            "rationale-too-long",
        ),
        (
            lambda d: d["themes"][0].__setitem__("reinforces", []),
            "coverage-empty-reinforces",
        ),
        (
            lambda d: d["themes"][0].__setitem__("reinforces", ['bad "quote"']),
            "reinforces-bad-char",
        ),
        (
            lambda d: d["themes"][0].__setitem__("reinforces", [123]),
            "reinforces-non-string",
        ),
        (
            lambda d: d["themes"][0].__setitem__("challenges", ["bad char"]),
            "challenges-bad-char",
        ),
        (
            lambda d: d["themes"][0].__setitem__("repos", ["bogus-repo"]),
            "invalid-repo-key",
        ),
        (
            lambda d: d["themes"][0].__setitem__("repos", []),
            "repos-missing-for-repo-line",
        ),
        (
            lambda d: d["themes"][0].__setitem__("repos", "akc"),
            "repos-not-a-list",
        ),
        (
            lambda d: d["themes"][1].__setitem__("repos", ["akc"]),
            "repos-on-explore-line",
        ),
        (
            lambda d: d["themes"][0].__setitem__("mode", "explore"),
            "explore-mode-on-repo-line",
        ),
        (
            lambda d: d["themes"][1].__setitem__("mode", "coverage"),
            "coverage-mode-on-explore-line",
        ),
        (
            lambda d: d["themes"][0].update(
                {"mode": "frontier", "reinforces": [], "challenges": []}
            ),
            "frontier-all-relations-empty",
        ),
        (
            lambda d: d["themes"][1].__setitem__("reinforces", ["concept/x"]),
            "explore-with-reinforces",
        ),
        (
            lambda d: d["themes"][0].__setitem__("mode", ["coverage"]),
            "mode-not-a-string",
        ),
        (
            lambda d: d["themes"].__setitem__(0, "not-a-dict"),
            "theme-not-a-dict",
        ),
        (
            lambda d: d["themes"][1].update(d["themes"][0] | {"slug": "dup-slug"}),
            "duplicate-track",
        ),
    ],
    ids=[
        "wrong-count",
        "invalid-track",
        "invalid-slug",
        "missing-key",
        "topic-too-long",
        "rationale-too-long",
        "coverage-empty-reinforces",
        "reinforces-bad-char",
        "reinforces-non-string",
        "challenges-bad-char",
        "invalid-repo-key",
        "repos-missing-for-repo-line",
        "repos-not-a-list",
        "repos-on-explore-line",
        "explore-mode-on-repo-line",
        "coverage-mode-on-explore-line",
        "frontier-all-relations-empty",
        "explore-with-reinforces",
        "mode-not-a-string",
        "theme-not-a-dict",
        "duplicate-track",
    ],
)
def test_validate_theme_rejects(monkeypatch, capsys, mutate, reason):
    d = json.loads(_valid_themes())
    mutate(d)
    rc, out, err = run_cmd(
        monkeypatch, capsys, ["validate-theme", CONFIG], json.dumps(d)
    )
    assert rc == 1


@pytest.mark.unit
def test_validate_theme_no_tracks_config_errors(monkeypatch, capsys):
    rc, out, err = run_cmd(
        monkeypatch, capsys, ["validate-theme", CONFIG_NO_TRACKS], _valid_themes()
    )
    assert rc == 1
    assert "No tracks defined" in err


@pytest.mark.unit
def test_validate_theme_no_json_object_errors(monkeypatch, capsys):
    rc, out, err = run_cmd(
        monkeypatch, capsys, ["validate-theme", CONFIG], "no braces here"
    )
    assert rc == 1
    assert "No JSON object found" in err


@pytest.mark.unit
def test_validate_theme_malformed_json_in_braces_errors(monkeypatch, capsys):
    # 波括弧はあるが JSON として壊れている → JSONDecodeError 経路
    rc, out, err = run_cmd(
        monkeypatch, capsys, ["validate-theme", CONFIG], "{themes: [unquoted]}"
    )
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


# === report-dir ===


@pytest.mark.unit
def test_report_dir_joins_vault_and_output(monkeypatch, capsys):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["report-dir", CONFIG])
    assert rc == 0
    assert out.strip() == "/tmp/fixture-vault/daily-research"


@pytest.mark.unit
def test_report_dir_missing_output_dir_is_empty(monkeypatch, capsys):
    # output_dir 欠落時は空文字 → 呼び出し側 (ctl-015) はゲートを skip する
    rc, out, _ = run_cmd(monkeypatch, capsys, ["report-dir", CONFIG_NO_TRACKS])
    assert rc == 0
    assert out.strip() == ""


# === themes-log ===


@pytest.mark.unit
def test_themes_log(monkeypatch, capsys):
    arg = json.dumps(
        {
            "themes": [
                {
                    "track": "attribution",
                    "repos": ["authorship"],
                    "mode": "frontier",
                    "topic": "Hello",
                },
                {"track": "tech", "topic": "World"},
            ]
        }
    )
    rc, out, _ = run_cmd(monkeypatch, capsys, ["themes-log", arg])
    assert rc == 0
    assert (
        out.strip()
        == 'Pass 1 themes: attribution[authorship/frontier]="Hello", tech="World"'
    )


# === tracks ===


@pytest.mark.unit
def test_tracks_emits_line_repo_tsv(monkeypatch, capsys):
    # 1 repo 1 行。3 本の自由探索 line は 0 行。
    rc, out, _ = run_cmd(monkeypatch, capsys, ["tracks", CONFIG])
    assert rc == 0
    lines = [ln for ln in out.splitlines() if ln]
    assert len(lines) == 3
    assert "agent_systems\takc\t/tmp/fixture-repos/agent-knowledge-cycle" in lines
    assert (
        "agent_systems\tcontemplative\t/tmp/fixture-repos/contemplative-agent" in lines
    )
    assert "agent_systems\taap\t/tmp/fixture-repos/agent-attribution-practice" in lines
    assert not any(
        ln.startswith(("human_ai_publics\t", "tech\t", "software_paradigms\t"))
        for ln in lines
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
    assert (
        "Track: agent_systems (旧 track: agent_cognition, akc, contemplative, aap を含む)"
        in out
    )
    assert "Old cognition topic" in out
    assert "Old AAP topic" in out
    assert "Old AKC topic" in out
    assert "Track: tech" in out
    assert "Old ai_dev topic" in out  # tech の alias ai_dev も集約
    assert "Track: human_ai_publics" not in out  # 新 line は旧履歴を継承しない
    assert "Track: software_paradigms" not in out  # 履歴が無い line は表示しない
    assert "should be filtered" not in out  # 未定義 track は除外
    assert "Old attribution line should stay historical" not in out


@pytest.mark.unit
def test_past_themes_missing_file_is_empty(monkeypatch, capsys, tmp_path):
    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["past-themes", str(tmp_path / "nope.json"), CONFIG]
    )
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
    rc, _, err = run_cmd(
        monkeypatch, capsys, ["graph-health", str(tmp_path / "nope.jsonld")]
    )
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


# === cluster-report ===


def _write_cluster_graph(tmp_path, today):
    """subCluster 頻度テスト用の graph.jsonld を生成。
    fixture config は saturated_top_n=2 / recent_days=90 / recent_min=3。"""
    from datetime import timedelta

    old = (today - timedelta(days=200)).isoformat()
    recent = (today - timedelta(days=5)).isoformat()
    articles = []
    # cluster_a: 全期間 5 回 (古い) → top-N 入り
    for i in range(5):
        articles.append(
            {
                "@type": "Article",
                "name": f"a{i}",
                "datePublished": old,
                "broadCluster": "dr:cluster/broad_x",
                "subCluster": ["dr:cluster/cluster_a"],
            }
        )
    # cluster_b: 全期間 4 回 → top-N 入り
    for i in range(4):
        articles.append(
            {
                "@type": "Article",
                "name": f"b{i}",
                "datePublished": old,
                "broadCluster": "dr:cluster/broad_x",
                "subCluster": ["dr:cluster/cluster_b"],
            }
        )
    # cluster_c: 全期間 3 回だが全て直近 → recent_min=3 で飽和入り
    for i in range(3):
        articles.append(
            {
                "@type": "Article",
                "name": f"c{i}",
                "datePublished": recent,
                "broadCluster": "dr:cluster/broad_y",
                "subCluster": ["dr:cluster/cluster_c"],
            }
        )
    # cluster_d: 全期間 1 回 → 飽和しない
    articles.append(
        {
            "@type": "Article",
            "name": "d0",
            "datePublished": old,
            "broadCluster": "dr:cluster/broad_y",
            "subCluster": "dr:cluster/cluster_d",  # 文字列形式も許容
        }
    )
    # Article 以外のノードは無視される
    articles.append({"@type": "Thing", "name": "not-an-article"})
    g = tmp_path / "graph.jsonld"
    g.write_text(json.dumps({"@graph": articles}))
    return str(g)


@pytest.mark.unit
def test_cluster_report_saturation(monkeypatch, capsys, tmp_path):
    from datetime import date

    graph = _write_cluster_graph(tmp_path, date.today())
    rc, out, _ = run_cmd(monkeypatch, capsys, ["cluster-report", CONFIG, graph])
    assert rc == 0
    # top-2 (cluster_a, cluster_b) + 直近 3 回 (cluster_c) が飽和
    assert "dr:cluster/cluster_a (全期間 5 回" in out
    assert "dr:cluster/cluster_b" in out
    assert "dr:cluster/cluster_c" in out
    # 低頻度 cluster_d は飽和リストに入らない
    assert "cluster_d" not in out.split("broadCluster")[0]
    # broadCluster 分布は参考表示
    assert "dr:cluster/broad_x: 9 回" in out


@pytest.mark.unit
def test_cluster_report_missing_graph_errors(monkeypatch, capsys, tmp_path):
    rc, _, err = run_cmd(
        monkeypatch, capsys, ["cluster-report", CONFIG, str(tmp_path / "nope.jsonld")]
    )
    assert rc == 1
    assert "cluster report unavailable" in err


# === coverage-report ===


def _write_coverage_setup(tmp_path, reinforce_counts, engagements=(), questions=None):
    """coverage-report テスト用の config + repo graph + daily graph を生成する。

    reinforce_counts: {concept_fragment: 補強回数}
    engagements: [(field, concept_fragment)] — challenges / extends の関与
    """
    base = "https://example.com/vocab#"
    concepts = [
        {"@id": f"{base}{frag}", "@type": "Concept", "name": frag.split("/")[-1]}
        for frag in reinforce_counts
    ]
    concepts.append(
        {
            "@id": "https://example.com/paper1",
            "@type": "ExternalReference",
            "name": "Adopted Paper One",
        }
    )
    repo_graph = tmp_path / "repo_a.jsonld"
    repo_graph.write_text(json.dumps({"@graph": concepts}))

    articles = []
    for frag, cnt in reinforce_counts.items():
        for i in range(cnt):
            articles.append(
                {
                    "@type": "Article",
                    "name": f"reinforce {frag} #{i}",
                    "datePublished": f"2026-01-{i + 1:02d}",
                    "reinforces": [f"{base}{frag}"],
                }
            )
    for field, frag in engagements:
        articles.append(
            {
                "@type": "Article",
                "name": f"{field} {frag}",
                "datePublished": "2026-02-01",
                field: [f"{base}{frag}"],
            }
        )
    daily_graph = tmp_path / "graph.jsonld"
    daily_graph.write_text(json.dumps({"@graph": articles}))

    q_line = ""
    if questions:
        q_line = "frontier_questions = " + json.dumps(questions)
    config = tmp_path / "config.toml"
    config.write_text(
        f"""
[coverage]
frontier_threshold = 0

[tracks.line_x]
name = "Line X"

[[tracks.line_x.repos]]
key = "repo_a"
target_repo = "/tmp/fixture-repos/repo-a"
target_graph = "{repo_graph}"
{q_line}

[tracks.free]
name = "Free"
"""
    )
    return str(config), str(daily_graph)


@pytest.mark.unit
def test_coverage_report_coverage_mode(monkeypatch, capsys, tmp_path):
    # 未補強 1 + 薄い 1 + 厚い 1 → coverage モード
    config, graph = _write_coverage_setup(
        tmp_path,
        {"concept/zero": 0, "concept/thin": 1, "concept/thick": 3},
        questions=["standing question?"],
    )
    rc, out, _ = run_cmd(monkeypatch, capsys, ["coverage-report", config, graph])
    assert rc == 0
    assert "MODE: coverage" in out
    assert "未補強 (0 件) — 最優先:" in out
    assert "concept/zero" in out
    assert "薄い (1-2 件):" in out
    assert "厚い (3+ 件) — 再訪は新展開時のみ:" in out
    # coverage モードでは frontier_questions は副次ガイド
    assert "常設フロンティア質問 (副次ガイド" in out
    assert "standing question?" in out
    # 自由探索 line は coverage report に出ない
    assert "Line: free" not in out
    # ExternalReference 禁止リスト
    assert "Adopted Paper One" in out


@pytest.mark.unit
def test_coverage_report_frontier_mode(monkeypatch, capsys, tmp_path):
    # 全 concept 厚い → frontier モード。質問が最優先で表示される
    config, graph = _write_coverage_setup(
        tmp_path,
        {"concept/t1": 3, "concept/t2": 4},
        questions=["diffusion measurement?"],
    )
    rc, out, _ = run_cmd(monkeypatch, capsys, ["coverage-report", config, graph])
    assert rc == 0
    assert "MODE: frontier" in out
    assert "常設フロンティア質問 (最優先の探索軸):" in out
    assert "diffusion measurement?" in out
    assert "全 concept (挑戦・矛盾・拡張の対象として再訪可):" in out
    # frontier モードでは coverage 分類ラベルを出さない
    assert "未補強 (0 件) — 最優先:" not in out


@pytest.mark.unit
def test_coverage_report_engagement_union_dedup(monkeypatch, capsys, tmp_path):
    # challenges の関与は『既出』に出る (主ソース dedup 用) が、
    # 厚み判定は reinforces のみ → challenges 1 件では未補強のまま
    config, graph = _write_coverage_setup(
        tmp_path,
        {"concept/challenged": 0},
        engagements=[("challenges", "concept/challenged")],
    )
    rc, out, _ = run_cmd(monkeypatch, capsys, ["coverage-report", config, graph])
    assert rc == 0
    assert "MODE: coverage" in out
    # reinforces 0 だが challenges 既出があるので「薄い」扱い (既出行を表示)
    assert "既出: 2026-02-01 challenges concept/challenged" in out
    assert "(補強 0 回)" in out


@pytest.mark.unit
def test_coverage_report_multi_repo_line_has_independent_modes(
    monkeypatch, capsys, tmp_path
):
    # 1 line = 2 repos で、repo ごとに独立して mode 判定されること
    # (repo_a は gap あり → coverage、repo_b は全て厚い → frontier)
    base = "https://example.com/vocab#"
    repo_a = tmp_path / "repo_a.jsonld"
    repo_a.write_text(
        json.dumps(
            {
                "@graph": [
                    {"@id": f"{base}concept/gap", "@type": "Concept", "name": "gap"}
                ]
            }
        )
    )
    repo_b = tmp_path / "repo_b.jsonld"
    repo_b.write_text(
        json.dumps(
            {
                "@graph": [
                    {"@id": f"{base}concept/thick", "@type": "Concept", "name": "thick"}
                ]
            }
        )
    )
    articles = [
        {
            "@type": "Article",
            "name": f"r{i}",
            "datePublished": f"2026-01-{i + 1:02d}",
            "reinforces": [f"{base}concept/thick"],
        }
        for i in range(3)
    ]
    graph = tmp_path / "graph.jsonld"
    graph.write_text(json.dumps({"@graph": articles}))
    config = tmp_path / "config.toml"
    config.write_text(
        f"""
[coverage]
frontier_threshold = 0

[tracks.line_x]
name = "Line X"

[[tracks.line_x.repos]]
key = "repo_a"
target_repo = "/tmp/fixture-repos/repo-a"
target_graph = "{repo_a}"

[[tracks.line_x.repos]]
key = "repo_b"
target_repo = "/tmp/fixture-repos/repo-b"
target_graph = "{repo_b}"
"""
    )
    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["coverage-report", str(config), str(graph)]
    )
    assert rc == 0
    assert "Repo: repo_a (repo: repo-a, 1 concepts)  MODE: coverage" in out
    assert "Repo: repo_b (repo: repo-b, 1 concepts)  MODE: frontier" in out


@pytest.mark.unit
def test_coverage_report_old_schema_config_errors(monkeypatch, capsys):
    rc, _, err = run_cmd(
        monkeypatch,
        capsys,
        ["coverage-report", str(FIXTURES / "config-old-schema.toml")],
    )
    assert rc == 1
    assert "legacy schema" in err


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
