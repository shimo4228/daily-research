"""scripts/dev/ (隔離 run の道具) の壊れやすい部分の単体テスト。

対象: config の書き換え (課金経路と vault だけを変え、他の値を保つ)、ログからの result JSON の振り分け、
集約時の課金経路・隔離の判定、eval の指標の計算、compare の表。dev 道具なので coverage の対象外。
"""

import json
import os
import pathlib
import sys
import time
import tomllib

import pytest

DEV = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "dev"
sys.path.insert(0, str(DEV))

import compare  # noqa: E402
import eval_run  # noqa: E402
import sandbox_lib  # noqa: E402

CONFIG = """[general]
vault_path = "/real/vault"
output_dir = "daily-research"
self_signals = [
  "example-author",
]

[billing]
mode = "api"
env_file = "~/.config/x/env"

[tracks.wide]
name = "Wide"
mode = "ecosystem"
daily = true

[tracks.akc]
aliases = ["old_akc"]

[[tracks.akc.repos]]
key = "akc"
target_repo = "/repos/akc"
"""


# === rewrite-config ===


NO_KEY = "/sandbox/no-api-key/env"


@pytest.mark.unit
def test_rewrite_config_changes_only_billing_mode_env_file_and_vault():
    out = tomllib.loads(sandbox_lib.rewrite_config_text(CONFIG, "/sandbox/vault", NO_KEY))
    before = tomllib.loads(CONFIG)
    assert out["billing"]["mode"] == "subscription"
    # 本物の key file (~/.config/x/env) を指したままにしない
    assert out["billing"]["env_file"] == NO_KEY
    assert out["general"]["vault_path"] == "/sandbox/vault"
    # 他 section の同名キー (tracks.wide.mode) は触らない
    assert out["tracks"]["wide"]["mode"] == "ecosystem"
    before["billing"]["mode"] = "subscription"
    before["billing"]["env_file"] = NO_KEY
    before["general"]["vault_path"] = "/sandbox/vault"
    assert out == before


@pytest.mark.unit
def test_rewrite_config_adds_missing_billing_section_and_vault_key():
    """env_file が無い config にも書く (既定値 ~/.config/daily-research/env が本物を指しうる)。"""
    text = '[general]\noutput_dir = "d"\n\n[tracks.a]\nname = "A"\n'
    out = tomllib.loads(sandbox_lib.rewrite_config_text(text, "/v", NO_KEY))
    assert out["billing"] == {"mode": "subscription", "env_file": NO_KEY}
    assert out["general"] == {"vault_path": "/v", "output_dir": "d"}
    assert out["tracks"]["a"]["name"] == "A"


@pytest.mark.unit
def test_rewrite_config_escapes_awkward_vault_paths():
    path = '/tmp/My "Vault" \\ 日本語'
    out = tomllib.loads(sandbox_lib.rewrite_config_text(CONFIG, path, NO_KEY))
    assert out["general"]["vault_path"] == path


@pytest.mark.unit
def test_rewrite_config_refuses_a_multiline_value_it_cannot_replace():
    text = '[billing]\nmode = """\napi"""\n'
    with pytest.raises((ValueError, tomllib.TOMLDecodeError)):
        sandbox_lib.rewrite_config_text(text, "/v", NO_KEY)


@pytest.mark.unit
def test_rewrite_config_cli_refuses_an_env_file_that_exists(tmp_path):
    src, dst, key = tmp_path / "c.toml", tmp_path / "d.toml", tmp_path / "env"
    src.write_text(CONFIG, encoding="utf-8")
    key.write_text("x\n", encoding="utf-8")
    assert sandbox_lib.cmd_rewrite_config([str(src), str(dst), "/v", str(key)]) == 1
    assert not dst.exists()


@pytest.mark.unit
def test_line_history_includes_aliases_in_date_order():
    topics = [
        {"date": "2026-11-02", "track": "akc", "question": "b"},
        {"date": "2026-10-01", "track": "old_akc", "question": "a"},
        {"date": "2026-11-03", "track": "wide", "question": "c"},
    ]
    tracks = tomllib.loads(CONFIG)["tracks"]
    assert [t["question"] for t in sandbox_lib.line_history(topics, tracks, "akc")] == ["a", "b"]


# === log / stream-json の解析 ===

LOG = """[2026-11-08 05:00:01] === Starting daily research ===
[2026-11-08 05:00:01] Billing: subscription (Max plan OAuth)
[2026-11-08 05:00:09] === Line: desire (/repos/desire) ===
{"type":"result","is_error":true,"num_turns":3,"credential_expires_at":"2026-12-01T00:00:00Z"}
[2026-11-08 05:01:00] WARN: Line desire failed (E_FATAL, exit 1) — retrying once
{"type":"result","is_error":false,"num_turns":28,"total_cost_usd":0.8,"credential_expires_at":"2026-12-01T00:00:00Z"}
[2026-11-08 05:13:43] === Clarity pass: 2026-11-08_desire_x.md ===
{"type":"result","is_error":false,"num_turns":8,"credential_expires_at":"2026-12-01T00:00:00Z"}
"""


@pytest.mark.unit
def test_parse_log_splits_call1_attempts_and_call2():
    p = sandbox_lib.parse_log(LOG)
    assert p["billing"] == ["subscription"]
    assert [d["num_turns"] for d in p["call1"]] == [3, 28]
    assert [d["num_turns"] for d in p["call2"]] == [8]
    assert p["clarity_ts"] == "2026-11-08 05:13:43"
    assert p["clarity_note"] == "2026-11-08_desire_x.md"
    # 呼び出し回数の期待値: 呼1 = 1 + retry 1 回、呼2 = Clarity pass の行 1 本
    assert (p["call1_expected"], p["call2_expected"]) == (2, 1)


@pytest.mark.unit
@pytest.mark.parametrize(
    "log,expected",
    [
        # cwd が無い line は attempt loop に入らない
        (
            "[t] === Line: x (/gone) ===\n[t] WARN: target_repo が存在しない: /gone — line x を skip\n",
            0,
        ),
        # retry を告げた後で見送った (attempt 1 がノートを書いていた)
        (
            "[t] === Line: x (/r) ===\n[t] WARN: Line x failed (E_TRANSIENT, exit 124) — retrying once\n"
            "[t] WARN: Line x attempt 1 left a report or receipt — skipping retry, going to gate\n",
            1,
        ),
        ("[t] === Line: x (/r) ===\n", 1),
    ],
    ids=["cwd-missing", "retry-skipped", "one-attempt"],
)
def test_parse_log_counts_the_call1_attempts_from_the_loop_lines(log, expected):
    assert sandbox_lib.parse_log(log)["call1_expected"] == expected


@pytest.mark.unit
def test_init_auth_source_reads_only_the_init_event():
    init = {"type": "system", "subtype": "init", sandbox_lib.INIT_AUTH_FIELD: "none"}
    assert sandbox_lib.init_auth_source(json.dumps(init) + "\n") == "none"
    assert sandbox_lib.init_auth_source('{"type":"result"}') is None
    assert sandbox_lib.init_auth_source("not json") is None


def _fake_cli(tmp_path, body):
    cli = tmp_path / "fake-claude"
    cli.write_text("#!/bin/bash\n" + body, encoding="utf-8")
    cli.chmod(0o755)
    return str(cli)


@pytest.mark.unit
def test_auth_probe_stops_at_init_without_waiting_for_the_result(tmp_path):
    """init を読んだら止める: 応答の生成 (sleep の後の result と完了印) まで走らせない。cwd は渡したもの。"""
    work = tmp_path / "work"
    work.mkdir()
    done = tmp_path / "completed"
    init = json.dumps({"type": "system", "subtype": "init", sandbox_lib.INIT_AUTH_FIELD: "none"})
    # 子 (sleep) を先に起こして pid を残す — group ごと止まり、孤児が残らないことも見る
    cli = _fake_cli(
        tmp_path,
        f"pwd -P > '{tmp_path}/cwd'\nsleep 20 &\necho $! > '{tmp_path}/child'\n"
        f"echo '{init}'\nwait\necho '{{\"type\":\"result\"}}'\ntouch '{done}'\n",
    )
    t0 = time.monotonic()
    assert sandbox_lib.auth_probe([cli], str(work), timeout_s=10) == ("none", "init")
    assert time.monotonic() - t0 < 8
    assert not done.exists()
    assert (tmp_path / "cwd").read_text().strip() == str(work.resolve())
    child = int((tmp_path / "child").read_text())
    for _ in range(40):
        try:
            os.kill(child, 0)
        except ProcessLookupError:
            break
        time.sleep(0.05)
    else:
        pytest.fail(f"the probe left its child {child} running")


@pytest.mark.unit
def test_auth_probe_times_out_and_reports_a_missing_init(tmp_path):
    t0 = time.monotonic()
    assert sandbox_lib.auth_probe([_fake_cli(tmp_path, "sleep 20\n")], str(tmp_path), 1) == (
        "",
        "timeout",
    )
    assert time.monotonic() - t0 < 6
    quiet = _fake_cli(tmp_path, "echo not-json\n")
    assert sandbox_lib.auth_probe([quiet], str(tmp_path), 5) == ("", "exited-without-init")
    assert sandbox_lib.cmd_auth_probe(["--cwd", str(tmp_path)]) == 64


# === collect ===


def _fake_run(tmp_path, billing_line="subscription (Max plan OAuth)", auth_source="none", log=LOG):
    """sandbox の run 後の状態を作る。(args, marker の後に書いた本物側の dir) を返す。"""
    proj, out, report = tmp_path / "proj", tmp_path / "out", tmp_path / "vault" / "dr"
    real_report = tmp_path / "real" / "dr"
    for d in (proj / "logs", proj / "state" / "desire" / "runs", out, report, real_report):
        d.mkdir(parents=True)
    marker = tmp_path / "marker"
    marker.touch()
    old = time.time() - 60
    os.utime(marker, (old, old))
    log = log.replace("subscription (Max plan OAuth)", billing_line)
    (proj / "logs" / "2026-11-08.log").write_text(log, encoding="utf-8")
    runs = proj / "state" / "desire" / "runs"
    (runs / "2026-11-08.json").write_text('{"status": "brief"}', encoding="utf-8")
    (runs / "2026-11-08.verify.json").write_text('{"supported": 3}', encoding="utf-8")
    (report / "2026-11-08_desire_x.md").write_text("# x\n", encoding="utf-8")
    (proj / "metrics.jsonl").write_text('{"date": "a"}\n{"date": "2026-11-08"}\n', encoding="utf-8")
    meta_tsv = tmp_path / "meta.tsv"
    meta_tsv.write_text(f"api_key_source\t{auth_source}\ndr_exit:int\t0\n", encoding="utf-8")
    args = {
        "proj": str(proj),
        "out": str(out),
        "line": "desire",
        "date": "2026-11-08",
        "report_dir": str(report),
        "real_report_dir": str(real_report),
        "marker": str(marker),
        "main": "",
        "target": "",
        "meta_tsv": str(meta_tsv),
    }
    return args, real_report


@pytest.mark.unit
def test_collect_gathers_artifacts_and_validates(tmp_path):
    args, _ = _fake_run(tmp_path)
    rc, meta = sandbox_lib.collect(args)
    out = pathlib.Path(args["out"])
    assert rc == sandbox_lib.RC_OK
    assert meta["valid"] is True and meta["dr_exit"] == 0
    assert meta["note_name"] == "2026-11-08_desire_x.md"
    assert meta["call1_attempts"] == 2 and meta["call2_ran"] is True
    for name in ("receipt.json", "verify.json", "run.log", "call1.json", "call1.attempt1.json"):
        assert (out / name).is_file(), name
    assert json.loads((out / "metrics.json").read_text())["date"] == "2026-11-08"
    assert json.loads((out / "meta.json").read_text())["billing_ok"] is True
    assert [r["call"] for r in meta["call_auth"]] == ["call1#1", "call1#2", "call2#1"]
    assert all(r["ok"] for r in meta["call_auth"])
    assert meta["call_evidence"]["ok"] is True
    assert meta["call_evidence"]["call1"] == {"expected": 2, "results": 2}


_SUB = "subscription (Max plan OAuth)"
_MARK = ',"credential_expires_at":"2026-12-01T00:00:00Z"'


@pytest.mark.unit
@pytest.mark.parametrize(
    "billing_line,key_source,log",
    [
        ("api (key from /x/env; caps …)", "none", LOG),
        (_SUB, "ANTHROPIC_API_KEY", LOG),
        # 呼2 の result に OAuth の印が無い (= key の経路で走った呼び出し)
        (_SUB, "none", LOG.replace('"num_turns":8' + _MARK, '"num_turns":8')),
        # result が key の経路を名乗る版
        (_SUB, "none", LOG.replace('"num_turns":3', '"num_turns":3,"apiKeySource":"x"')),
        # retry の attempt 2 が result を残さずに終わった (timeout で kill) — 証拠の無い呼び出し
        (_SUB, "none", LOG.replace('{"type":"result","is_error":false,"num_turns":28', "{")),
        # 呼2 が result を残さなかった
        (_SUB, "none", LOG.replace('{"type":"result","is_error":false,"num_turns":8', "{")),
    ],
    ids=[
        "log-says-api",
        "probe-saw-a-key",
        "result-without-oauth-marker",
        "result-names-a-key",
        "call1-attempt-without-result",
        "call2-without-result",
    ],
)
def test_collect_marks_a_non_subscription_run_invalid(tmp_path, billing_line, key_source, log):
    args, _ = _fake_run(tmp_path, billing_line, key_source, log)
    rc, meta = sandbox_lib.collect(args)
    assert rc == sandbox_lib.RC_BILLING_INVALID
    assert meta["valid"] is False


@pytest.mark.unit
def test_collect_reports_writes_outside_the_sandbox(tmp_path):
    args, real_report = _fake_run(tmp_path)
    (real_report / "2026-11-08_desire_leak.md").write_text("leak", encoding="utf-8")
    rc, meta = sandbox_lib.collect(args)
    assert rc == sandbox_lib.RC_ISOLATION
    assert meta["isolation"]["violations"] == [str(real_report / "2026-11-08_desire_leak.md")]


# === eval の指標 ===

NOTE = """---
date: 2026-11-08
kind: article  # article | brief
question: "Q"
---

# 題

A 社は 2026-11-04 に新しい機能を公開した。これは外部の出来事であり、段落として十分な長さを持つ。

二つ目の段落は日付を持たないが、十分な長さを持つ文章で、導入すべきだと書いてしまっている。

三つ目の段落は 09-03 の system card に触れ、内容（推論であり断定しない）を述べる十分な長さの文。

## 機会メモ

なし

## ソース

- [a](https://example.com/a)
- [b](https://example.com/b)
"""


@pytest.mark.unit
def test_split_note_and_body_metrics(tmp_path):
    fm, body, sources = eval_run.split_note(NOTE)
    assert fm["kind"] == "article" and fm["question"] == "Q"
    assert "機会メモ" not in body and "題" not in body
    assert "example.com/a" in sources
    paras = eval_run.paragraphs(body)
    assert len(paras) == 3
    assert [bool(eval_run.DATE_RE.search(p)) for p in paras] == [True, False, True]
    path = tmp_path / "2026-11-08_desire_x.md"
    path.write_text(NOTE, encoding="utf-8")
    m = eval_run.analyze_note(str(path), "2026-11-08")
    assert m["date_coverage"] == round(2 / 3, 3)
    assert m["forbidden"]["should"] == 1
    assert m["epistemic_parentheticals"] == 1
    assert m["first_sentence_internal"] is False
    assert m["sources_section"] == 2
    # 出典 2 件 < min_sources 5 と本文長不足は soft、hard は無い
    assert m["lint_hard"] == 0 and m["lint_soft"] >= 1


@pytest.mark.unit
@pytest.mark.parametrize(
    "text",
    [
        "差は 10-20% の範囲",
        "1500-3000 件の投稿",
        "10-20 倍に増えた",
        "10-12件",
        "Market 2026 report",
    ],
)
def test_date_re_ignores_ranges_and_non_dates(text):
    assert not eval_run.DATE_RE.search(text)


@pytest.mark.unit
@pytest.mark.parametrize(
    "text",
    [
        "2026-11-04 に公開",
        "2026/11/4 の記事",
        "2026 年 11 月の発表",
        "11 月 4 日に公開",
        "09-03 の system card",
        "released Nov 4, 2026",
        "on 4 November 2026",
        "（May 2026）",
    ],
)
def test_date_re_finds_dates(text):
    assert eval_run.DATE_RE.search(text)


@pytest.mark.unit
def test_should_counts_prescriptions_but_not_adjectival_idioms():
    should = eval_run.FORBIDDEN["should"]
    assert len(should.findall("驚くべき速さで、恐るべき規模。然るべき手続きと来るべき変化")) == 0
    assert len(should.findall("導入すべきだ。見直すべき点がある")) == 2


@pytest.mark.unit
def test_calls_metrics_sums_every_attempt(tmp_path):
    a1 = {"total_cost_usd": 0.5, "num_turns": 3, "is_error": True, "usage": {"output_tokens": 10}}
    a2 = {
        "total_cost_usd": 0.81,
        "num_turns": 28,
        "is_error": False,
        "usage": {"output_tokens": 90},
    }
    (tmp_path / "call1.attempt1.json").write_text(json.dumps(a1), encoding="utf-8")
    (tmp_path / "call1.json").write_text(json.dumps(a2), encoding="utf-8")
    m = eval_run.calls_metrics(eval_run.call_results(str(tmp_path), "call1"))
    assert m["attempts"] == 2 and m["cost_usd"] == 1.31 and m["turns"] == 31
    assert m["output_tokens"] == 100 and m["is_error"] is False
    assert eval_run.calls_metrics(eval_run.call_results(str(tmp_path), "call2")) is None


@pytest.mark.unit
@pytest.mark.parametrize("draft_state,expect", [("clean", True), ("after-clarity-start", False)])
def test_evaluate_uses_the_draft_only_when_it_was_taken_before_call2(tmp_path, draft_state, expect):
    note = "2026-11-08_desire_x.md"
    meta = {"date": "2026-11-08", "line": "desire", "note_name": note, "draft": draft_state}
    (tmp_path / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
    (tmp_path / note).write_text(NOTE + "\n追記\n", encoding="utf-8")
    (tmp_path / "draft.md").write_text(NOTE, encoding="utf-8")
    r = eval_run.evaluate(str(tmp_path))
    assert (r["draft_vs_final"] is not None) is expect
    assert (r["draft"] is not None) is expect


@pytest.mark.unit
def test_novelty_takes_the_most_similar_past_question():
    hist = [
        {"date": "2026-11-01", "question": "AI に頼むことが尽きた一人称の証言は見つかるか"},
        {"date": "2026-11-02", "question": "まったく別の話題について"},
    ]
    n = eval_run.novelty("AI に頼むことが尽きた証言は見つかるか", hist)
    assert n["top"][0]["date"] == "2026-11-01"
    assert 0.5 < n["max_jaccard"] <= 1.0
    assert eval_run.jaccard("abc", "abc") == 1.0
    assert eval_run.novelty(None, hist)["max_jaccard"] is None


@pytest.mark.unit
def test_verify_and_evidence_metrics(tmp_path):
    v = eval_run.verify_metrics({"supported": 3, "partial": 1, "edits": True})
    assert v["total"] == 4 and v["supported_rate"] == 0.75 and v["edits"] == 0
    assert eval_run.verify_metrics(None) == {"ran": False}
    ev = tmp_path / "evidence.md"
    ev.write_text(
        "| claim_id | x | fetch_status |\n|---|---|---|\n| C1 | p | 本文確認済（要旨のみ） |\n| C2 | q | 取得失敗 |\n",
        encoding="utf-8",
    )
    e = eval_run.evidence_metrics(str(ev))
    assert e["claims"] == 2
    assert e["fetch_status"]["本文確認済"] == 1 and e["fetch_status"]["取得失敗"] == 1


@pytest.mark.unit
def test_call_metrics_reads_usage_and_searches():
    d = {
        "total_cost_usd": 0.81234,
        "num_turns": 28,
        "duration_ms": 205000,
        "usage": {"input_tokens": 26, "output_tokens": 13337, "cache_read_input_tokens": 9},
        "modelUsage": {"claude-opus": {"webSearchRequests": 5}},
        "permission_denials": [{"tool_name": "Bash"}],
    }
    m = eval_run.call_metrics(d)
    assert m["cost_usd"] == 0.8123 and m["turns"] == 28 and m["duration_s"] == 205
    assert m["searches"] == 5 and m["cache_read_input_tokens"] == 9
    assert m["denied_tools"] == ["Bash"]
    assert eval_run.call_metrics({}) is None


# === compare ===


@pytest.mark.unit
def test_compare_flattens_and_shows_deltas_against_the_first_column():
    rows = [compare.flatten({"a": {"b": 1}, "s": "x"}), compare.flatten({"a": {"b": 3}, "s": "y"})]
    assert rows[0] == {"a.b": 1, "s": "x"}
    lines = compare.table(rows, ["A", "B"], ["a.b", "s", "missing"])
    assert lines[2] == "| a.b | 1 | 3 (+2) |"
    assert lines[3] == "| s | x | y |"
    assert len(lines) == 4  # 全列で欠けたキーの行は出さない
