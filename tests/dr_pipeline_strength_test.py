"""dr_pipeline のテストの強さ (mutation testing で見逃しが見つかった振る舞い) を固定する。

各テストは mutmut 3 の生き残り変異体 (survivor) が表す誤りのうち、本番の無人 run で起きうるもの
(境界値・off-by-one・例外の握りつぶし・型の取り違え・空入力・診断文の欠落) を殺すために書いた。
対象は朝の run が通る subcommand だけ。tests/dr_pipeline_test.py とは独立 (helper も複製する)。

測り方: dr_pipeline.py を root 直下に置いた写し (mutmut は module 名をパスから決めるので
scripts/lib/ のままだと trampoline が一致しない) で `mutmut run`。手順は commit 本文にある。
"""

import io
import json
import os
import pathlib
import sys

import dr_pipeline
import pytest

FIXTURES = pathlib.Path(__file__).parent / "fixtures"
CONFIG = str(FIXTURES / "config-lines.toml")
KEY_VAR = "ANTHROPIC" + "_API_KEY"  # secret scan の KEY=値 パターンに当てない


def run_cmd(monkeypatch, capsys, args, stdin=""):
    monkeypatch.setattr(sys, "stdin", io.StringIO(stdin))
    rc = dr_pipeline.main(args)
    out, err = capsys.readouterr()
    return rc, out, err


def _write(tmp_path, name, text):
    p = tmp_path / name
    p.write_text(text, encoding="utf-8")
    return str(p)


# === billing: [billing] の検証 (billing-config) ===


@pytest.mark.unit
@pytest.mark.parametrize(
    "body,named",
    [
        # 数値を引用符で書いた config は文字列。比較で TypeError にせず、key を名指して rc 2
        ('monthly_cap_usd = "100"', "monthly_cap_usd"),
        # bool は int の subclass。予約額の検査に当たらない位置の bool でも拒否する
        ("call1_max_usd = true", "call1_max_usd"),
        # 0 は「> 0」に反する。予約額の検査 (call1 + call2 <= daily) を通る位置でも拒否する
        ("call2_max_usd = 0", "call2_max_usd"),
        ('env_file = ""', "env_file"),
        ("env_file = 3", "env_file"),
        ('mode = "apikey"', "mode"),
        ("unknown_key = 1", "unknown_key"),
        ("daily_cap_usd = 5\ncall1_max_usd = 4\ncall2_max_usd = 2", "daily_cap_usd"),
    ],
    ids=[
        "quoted-number",
        "bool-call1",
        "zero-call2",
        "empty-env-file",
        "non-string-env-file",
        "bad-mode",
        "unknown-key",
        "reserve-over-daily",
    ],
)
def test_billing_config_rejects_and_names_the_key(monkeypatch, capsys, tmp_path, body, named):
    cfg = _write(tmp_path, "c.toml", "[billing]\n" + body + "\n")
    rc, out, err = run_cmd(monkeypatch, capsys, ["billing-config", cfg])
    assert rc == 2
    assert out == ""
    # shell (billing.sh) はこの stderr を BILLING_ERROR として log / notify に載せる。運用者が
    # どの key を直せばよいかは、この 1 行にしか書かれない
    assert err.startswith("billing-config: [billing")
    assert named in err


@pytest.mark.unit
def test_billing_config_accepts_equal_caps(monkeypatch, capsys, tmp_path):
    # 不変条件は call1 + call2 <= daily <= monthly (等号を含む)。上限ちょうどの設定は通す
    cfg = _write(
        tmp_path,
        "c.toml",
        '[billing]\nmode = "api"\nenv_file = "/x/env"\nmonthly_cap_usd = 5\n'
        "daily_cap_usd = 5\ncall1_max_usd = 3.5\ncall2_max_usd = 1.5\n",
    )
    rc, out, err = run_cmd(monkeypatch, capsys, ["billing-config", cfg])
    assert rc == 0, err
    assert out.rstrip("\n") == "api\t/x/env\t5\t5\t3.5\t1.5"


# === billing: env-key ===


@pytest.mark.unit
@pytest.mark.parametrize("quoted", ['""', "''"])
def test_env_key_empty_quoted_value_is_missing(monkeypatch, capsys, tmp_path, quoted):
    # 引用符だけの値は空。引用符 2 文字を key として出さない
    env = _write(tmp_path, "env", f"{KEY_VAR}={quoted}\n")
    rc, out, err = run_cmd(monkeypatch, capsys, ["env-key", env])
    assert rc == 1
    assert out == ""
    assert "missing" in err


@pytest.mark.unit
def test_env_key_unreadable_says_cannot_read(monkeypatch, capsys, tmp_path):
    missing = str(tmp_path / "nope")
    rc, out, err = run_cmd(monkeypatch, capsys, ["env-key", missing])
    assert rc == 1 and out == ""
    assert err == f"env-key: cannot read {missing}\n"


# === billing: spend-add / spend-gate (支出台帳と上限) ===


@pytest.mark.unit
def test_spend_add_ledger_row_schema_and_rounding(monkeypatch, capsys, tmp_path):
    ledger = tmp_path / "state" / "api-spend.jsonl"
    rc, out, _ = run_cmd(
        monkeypatch,
        capsys,
        ["spend-add", str(ledger), "2026-11-02", "akc", "call1"],
        '{"total_cost_usd": 0.123456}',
    )
    assert rc == 0
    assert out == "0.1235\n"
    row = json.loads(ledger.read_text(encoding="utf-8"))
    # 台帳の 1 行の契約: ts / date / line / call / cost_usd (見積もりのときだけ estimated)
    assert set(row) == {"ts", "date", "line", "call", "cost_usd"}
    assert row["date"] == "2026-11-02"
    assert row["line"] == "akc"
    assert row["call"] == "call1"
    assert row["cost_usd"] == 0.1235
    assert len(row["ts"]) == len("2026-11-02T05:00:00")


@pytest.mark.unit
def test_spend_add_bare_ledger_name_writes_in_cwd(monkeypatch, capsys, tmp_path):
    # dirname が空のパスは cwd に書く (余計な dir を作らない)
    monkeypatch.chdir(tmp_path)
    rc, _, _ = run_cmd(
        monkeypatch, capsys, ["spend-add", "l.jsonl", "2026-11-02", "akc", "call2"], "{}"
    )
    assert rc == 0
    assert sorted(os.listdir(tmp_path)) == ["l.jsonl"]


@pytest.mark.unit
def test_spend_gate_month_remaining_equal_to_reserve_is_ok(monkeypatch, capsys, tmp_path):
    # 月の残額 10 - 4.5 = 5.5 はちょうど予約額 → 通す (日の側と同じく >=)
    ledger = _write(tmp_path, "l.jsonl", '{"date": "2026-11-01", "cost_usd": 4.5}\n')
    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["spend-gate", ledger, "2026-11-02", "10", "50", "5.5"]
    )
    assert rc == 0
    assert out == "ok\t4.50\t0.00\n"


@pytest.mark.unit
def test_spend_gate_blank_line_does_not_stop_counting(monkeypatch, capsys, tmp_path):
    # 空行の後ろの支出も累計に入る (取りこぼすと上限の判定が甘くなる)
    ledger = _write(
        tmp_path,
        "l.jsonl",
        '{"date": "2026-11-02", "cost_usd": 1}\n\n{"date": "2026-11-02", "cost_usd": 2}\n',
    )
    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["spend-gate", ledger, "2026-11-02", "100", "10", "1"]
    )
    assert rc == 0
    assert out == "ok\t3.00\t3.00\n"


@pytest.mark.unit
def test_spend_gate_reports_count_of_unreadable_lines(monkeypatch, capsys, tmp_path):
    ledger = _write(
        tmp_path,
        "l.jsonl",
        '{broken\n{"date": "2026-11-02", "cost_usd": 1}\n[1, 2]\n{"date": "2026-11-02"}\n',
    )
    rc, out, err = run_cmd(
        monkeypatch, capsys, ["spend-gate", ledger, "2026-11-02", "100", "10", "1"]
    )
    assert rc == 2
    assert out == ""
    # 2 行 (非 JSON と非 object) が読めない。1 行目で数え止めない
    assert err == f"spend-gate: 2 unreadable line(s) in {ledger}\n"


@pytest.mark.unit
def test_spend_gate_unopenable_ledger_is_rc2(monkeypatch, capsys, tmp_path):
    # 台帳が開けない (存在しないのとは別) は rc 2 = 上限を判定できない。billing.sh は
    # rc 0/1 以外を「gate 自体の失敗」として log し、line を始めない
    ledger = tmp_path / "ledger-is-a-dir"
    ledger.mkdir()
    rc, out, err = run_cmd(
        monkeypatch, capsys, ["spend-gate", str(ledger), "2026-11-02", "100", "10", "1"]
    )
    assert rc == 2
    assert out == ""
    assert err.startswith(f"spend-gate: cannot read {ledger}: ")


@pytest.mark.unit
def test_billing_config_non_table_billing(monkeypatch, capsys, tmp_path):
    cfg = _write(tmp_path, "c.toml", "billing = 3\n")
    rc, out, err = run_cmd(monkeypatch, capsys, ["billing-config", cfg])
    assert rc == 2 and out == ""
    assert err == "billing-config: [billing] must be a table\n"


# === error-fields: 課金系の失敗の種類 ===


@pytest.mark.unit
@pytest.mark.parametrize(
    "stdin,expected",
    [
        ('{"is_error":true,"api_error_status":402}', "402\ttrue\tbilling"),
        # 成功した run の本文が API クレジットを論じていても課金エラーにしない
        (
            '{"is_error":false,"result":"a note on credit balance policies"}',
            "\tfalse\t",
        ),
        ('{"is_error":true,"result":"insufficient API credit"}', "\ttrue\tbilling"),
    ],
    ids=["payment-required-402", "credit-words-in-ok-result", "insufficient-credit"],
)
def test_error_fields_billing_kinds(monkeypatch, capsys, stdin, expected):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["error-fields"], stdin)
    assert rc == 0
    assert out.rstrip("\n") == expected


# === receipt-read: gate が line を落とした理由を log に残す ===


@pytest.mark.unit
@pytest.mark.parametrize(
    "obj,raw,reason",
    [
        (None, "{broken", "unreadable receipt: "),
        (None, "[1, 2]", "receipt is not a JSON object"),
        ({"status": "published"}, None, "invalid status 'published'"),
        (
            {"status": "quiet", "date": "2026-09-14"},
            None,
            "date mismatch '2026-09-14' != '2026-09-15'",
        ),
        ({"status": "quiet", "line": "aap"}, None, "line mismatch 'aap' != 'akc'"),
        ({"status": "article", "report": "../x.md"}, None, "invalid report name '../x.md'"),
        ({"status": "brief"}, None, "status brief requires report"),
    ],
    ids=["unreadable", "non-object", "status", "date", "line", "report-name", "no-report"],
)
def test_receipt_read_logs_the_reason(monkeypatch, capsys, tmp_path, obj, raw, reason):
    p = tmp_path / "receipt.json"
    p.write_text(raw if raw is not None else json.dumps(obj))
    rc, out, err = run_cmd(monkeypatch, capsys, ["receipt-read", str(p), "2026-09-15", "akc"])
    assert rc == 1
    assert out == ""
    # daily-research.sh は stderr を LOG_FILE に足す。line 失敗の理由はこの 1 行だけが持つ
    assert err.startswith("receipt-read: " + reason)
    assert err.count("\n") == 1


# === past-topics-append: 問いの履歴の記帳 ===


def _pta(monkeypatch, capsys, past, receipt, report="2026-09-15_akc_some-slug.md"):
    args = ["past-topics-append", str(past), str(receipt), "2026-09-15", "akc"]
    if report:
        args.append(report)
    return run_cmd(monkeypatch, capsys, args)


def _receipt_file(tmp_path, **over):
    d = {
        "date": "2026-09-15",
        "line": "akc",
        "status": "article",
        "report": "2026-09-15_akc_some-slug.md",
        "question": "Q1?",
        "reason": "r",
        "reason_code": "no_new_evidence",
        "answer_scope": "as of 2026-09-15",
        "title": "Some title",
    }
    d.update(over)
    p = tmp_path / "receipt.json"
    p.write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
    return p


@pytest.mark.unit
def test_past_topics_append_empty_string_field_warns(monkeypatch, capsys, tmp_path):
    past = tmp_path / "past_topics.json"
    rec = _receipt_file(tmp_path, title="", answer_scope="")
    rc, _, err = _pta(monkeypatch, capsys, past, rec)
    assert rc == 0
    assert "WARN receipt has no title" in err
    assert "WARN receipt has no answer_scope" in err
    entry = json.loads(past.read_text(encoding="utf-8"))["topics"][0]
    assert entry["title"] == "" and entry["answer_scope"] == ""


@pytest.mark.unit
def test_past_topics_append_collapses_whitespace(monkeypatch, capsys, tmp_path):
    # 履歴は 1 行 1 問いでプロンプトに入る。連続空白・前後の空白は 1 つに畳む
    past = tmp_path / "past_topics.json"
    rec = _receipt_file(tmp_path, question="  Does   X\t\tchange  Y?  ")
    rc, _, _ = _pta(monkeypatch, capsys, past, rec)
    assert rc == 0
    entry = json.loads(past.read_text(encoding="utf-8"))["topics"][0]
    assert entry["question"] == "Does X change Y?"


@pytest.mark.unit
def test_past_topics_append_temp_file_lives_next_to_target(monkeypatch, capsys, tmp_path):
    # os.replace の原子性は同じ filesystem の中でだけ成り立つ。一時 file は system の
    # tmp ではなく past_path と同じ dir に作る (tmp が使えない環境でも書ける)
    import tempfile

    monkeypatch.setattr(tempfile, "tempdir", str(tmp_path / "no-such-tmp"))
    past = tmp_path / "data" / "past_topics.json"
    past.parent.mkdir()
    rec = _receipt_file(tmp_path)
    rc, _, err = _pta(monkeypatch, capsys, past, rec)
    assert rc == 0, err
    assert len(json.loads(past.read_text(encoding="utf-8"))["topics"]) == 1
    assert os.listdir(past.parent) == ["past_topics.json"]  # 一時 file を残さない


@pytest.mark.unit
def test_past_topics_append_write_failure_keeps_file_and_cleans_temp(monkeypatch, capsys, tmp_path):
    past = tmp_path / "past_topics.json"
    old = '{"version": 1, "topics": []}\n'
    past.write_text(old, encoding="utf-8")
    rec = _receipt_file(tmp_path)

    def boom(src, dst):
        raise OSError("disk full")

    monkeypatch.setattr(os, "replace", boom)
    rc, _, err = _pta(monkeypatch, capsys, past, rec)
    assert rc == 1
    assert err == "past-topics-append: write failed: disk full\n"
    assert past.read_text(encoding="utf-8") == old
    assert sorted(os.listdir(tmp_path)) == ["past_topics.json", "receipt.json"]


@pytest.mark.unit
@pytest.mark.parametrize(
    "existing,receipt_raw,report,reason",
    [
        (None, None, "../evil.md", "invalid report name '../evil.md'"),
        (None, "{broken", "", "unreadable receipt: "),
        (None, '"a string"', "", "receipt is not a JSON object"),
        ("{not json", None, "", "existing file unreadable, not writing: "),
        ('{"topics": 3}', None, "", "existing file has no topics list, not writing"),
    ],
    ids=["report-name", "unreadable-receipt", "non-object-receipt", "corrupt", "no-topics"],
)
def test_past_topics_append_refusals_are_rc1_with_reason(
    monkeypatch, capsys, tmp_path, existing, receipt_raw, report, reason
):
    past = tmp_path / "past_topics.json"
    if existing is not None:
        past.write_text(existing, encoding="utf-8")
    if receipt_raw is None:
        rec = _receipt_file(tmp_path)
    else:
        rec = tmp_path / "receipt.json"
        rec.write_text(receipt_raw, encoding="utf-8")
    rc, _, err = _pta(monkeypatch, capsys, past, rec, report)
    # 契約は rc 1 (shell は失敗を log して run 開始時の退避 .bak を残す)
    assert rc == 1
    assert err.startswith("past-topics-append: " + reason)
    if existing is None:
        assert not past.exists()
    else:
        assert past.read_text(encoding="utf-8") == existing


# === log-summary: SUMMARY 行は metrics-backfill の _SUMMARY_RE が読む機械契約 ===

RUN_FULL = (
    '{"total_cost_usd":0.123456,"num_turns":7,"duration_ms":1500,'
    '"usage":{"input_tokens":11,"output_tokens":22},"modelUsage":{"m":{"webSearchRequests":4}}}'
)


@pytest.mark.unit
@pytest.mark.parametrize("label", ["Run(akc)", "Run(ai-dev_2)", "Clarity"])
def test_log_summary_line_round_trips_through_backfill_regex(monkeypatch, capsys, label):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["log-summary", label], RUN_FULL)
    assert rc == 0
    # duration は ms → s の四捨五入 (1500 ms = 2 s)。cost は 4 桁
    expected = (
        f"SUMMARY {label}: cost=$0.1235 turns=7 duration=2s tokens_in=11 tokens_out=22 searches=4"
    )
    assert out == expected + "\n"
    # log.sh の log() が付ける時刻 prefix 付きの 1 行を、backfill の正規表現が全項目読み戻す
    m = dr_pipeline._SUMMARY_RE.search(f"[2026-11-02 05:10:00] {out.strip()}")
    assert m is not None
    assert m.groups() == ("2026-11-02 05:10:00", label, "0.1235", "7", "2", "11", "22", "4")


@pytest.mark.unit
@pytest.mark.parametrize(
    "stdin",
    [
        '{"total_cost_usd":1,"num_turns":1,"duration_ms":0,"usage":{}}',
        # server_tool_use が dict でない (形の崩れた usage) も 0 件として 1 行を出す
        '{"total_cost_usd":1,"num_turns":1,"usage":{"server_tool_use":["x"]}}',
    ],
    ids=["empty-usage", "non-dict-server-tool-use"],
)
def test_log_summary_missing_fields_are_zero(monkeypatch, capsys, stdin):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["log-summary", "Run(akc)"], stdin)
    assert rc == 0
    # 検索 0 件は searches= を書かない (backfill の正規表現では省略可の群)
    assert out == "SUMMARY Run(akc): cost=$1.0000 turns=1 duration=0s tokens_in=0 tokens_out=0\n"


# === searches: 検索回数 (quiet-suspect の入力) の型の取り違え ===


@pytest.mark.unit
@pytest.mark.parametrize(
    "stdin,expected",
    [
        ("5", 0),  # JSON だが object でない
        ('{"tool_counts":{"WebSearch":3}}', 3),
        ('{"tool_counts":{"WebFetch":2}}', 2),
        # bool は int の subclass、小数・負値・文字列は回数でない
        ('{"tool_counts":{"WebSearch":true,"WebFetch":2.5}}', 0),
        ('{"tool_counts":{"WebSearch":-3,"WebFetch":"4"}}', 0),
        # 検索しなかった model の modelUsage には webSearchRequests が無い
        ('{"modelUsage":{"opus":{"inputTokens":5},"haiku":{"webSearchRequests":2}}}', 2),
        ('{"usage":{"server_tool_use":"x"}}', 0),
    ],
    ids=[
        "scalar-json",
        "websearch-only",
        "webfetch-only",
        "bool-and-float",
        "negative-and-string",
        "model-without-key",
        "non-dict-server-tool-use",
    ],
)
def test_searches_counts_only_positive_ints(monkeypatch, capsys, stdin, expected):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["searches"], stdin)
    assert rc == 0
    assert out == f"{expected}\n"


# === metrics-append: metrics.jsonl は expect-check / dr-review が読む機械契約 ===


def _metrics(monkeypatch, capsys, tmp_path, stdin, *, report_count="1", extra=()):
    path = tmp_path / "metrics.jsonl"
    rc, out, err = run_cmd(
        monkeypatch,
        capsys,
        ["metrics-append", str(path), "2026-11-02", "OK", report_count, "0", *extra],
        stdin,
    )
    assert rc == 0, err
    return json.loads(path.read_text(encoding="utf-8")), out


@pytest.mark.unit
def test_metrics_append_pass2_has_every_field(monkeypatch, capsys, tmp_path):
    rec, _ = _metrics(monkeypatch, capsys, tmp_path, f"RUN\t{RUN_FULL}\n")
    assert rec["pass2"] == {
        "cost": 0.1235,
        "turns": 7,
        "duration_s": 2,
        "tokens_in": 11,
        "tokens_out": 22,
        "searches": 4,
    }
    assert rec["total_cost"] == 0.1235


ZERO_PASS = {"cost": 0, "turns": 0, "duration_s": 0, "tokens_in": 0, "tokens_out": 0, "searches": 0}


@pytest.mark.unit
@pytest.mark.parametrize(
    "run_json",
    [
        # timeout や error 終了の result は値が null で来る
        '{"total_cost_usd":null,"num_turns":null,"duration_ms":null,'
        '"usage":{"input_tokens":null,"output_tokens":null}}',
        # key ごと無い (usage も無い) result
        '{"type":"result"}',
    ],
    ids=["nulls", "missing-keys"],
)
def test_metrics_append_null_or_missing_values_are_zero(monkeypatch, capsys, tmp_path, run_json):
    rec, _ = _metrics(monkeypatch, capsys, tmp_path, f"RUN\t{run_json}\n")
    assert rec["pass2"] == ZERO_PASS
    assert rec["total_cost"] == 0


@pytest.mark.unit
def test_metrics_append_bad_lines_do_not_stop_later_lines(monkeypatch, capsys, tmp_path):
    # 壊れた行・空行の後ろに来た正常な行も集計する (収集は non-fatal で、1 行で打ち切らない)
    lint = '{"date":"2026-11-02","files":1,"hard_fail":0,"soft_fail":0,"results":[]}'
    verify = '{"supported":3,"partial":0,"unsupported":1,"unverifiable":0,"edits":2,"ran":true}'
    stdin = "\n".join(
        [
            "RUN\t{broken",
            "VERIFY\t{broken",
            "LINT\t{broken",
            "",
            f"RUN\t{RUN_FULL}",
            f"VERIFY\t{verify}",
            f"LINT\t{lint}",
            "STATE\takc\tarticle",
        ]
    )
    rec, out = _metrics(monkeypatch, capsys, tmp_path, stdin)
    assert rec["pass2"]["turns"] == 7
    assert rec["lint"] == json.loads(lint)
    assert rec["verification"] == {
        "supported": 3,
        "partial": 0,
        "unsupported": 1,
        "unverifiable": 0,
        "edits": 2,
        "lines_verified": 1,
    }
    assert rec["line_states"]["article"] == 1
    assert out == "metrics: appended 2026-11-02 (OK, 1 reports, 1 runs)\n"


@pytest.mark.unit
@pytest.mark.parametrize(
    "stdin,expected",
    [
        # JSON が壊れていても ok フラグは残す (ok=1 は成功)
        ("CLARITY\t1\tnot-json\n", {"ran": True, "ok": True}),
        # 複数 line で全部壊れていたら費用の key は作らない (0 円と取り違えない)
        ("CLARITY\t1\tx\nCLARITY\t1\ty\n", {"ran": True, "ok": True}),
    ],
    ids=["single-broken-ok", "all-broken"],
)
def test_metrics_append_clarity_without_metrics(monkeypatch, capsys, tmp_path, stdin, expected):
    rec, _ = _metrics(monkeypatch, capsys, tmp_path, stdin)
    assert rec["clarity_pass"] == expected


@pytest.mark.unit
def test_metrics_append_clarity_all_ok_is_ok(monkeypatch, capsys, tmp_path):
    rec, _ = _metrics(
        monkeypatch, capsys, tmp_path, f"CLARITY\t1\t{RUN_FULL}\nCLARITY\t1\t{RUN_FULL}\n"
    )
    assert rec["clarity_pass"] == {
        "ran": True,
        "ok": True,
        "cost": 0.247,
        "turns": 14,
        "duration_s": 4,
        "tokens_in": 22,
        "tokens_out": 44,
        "searches": 8,
    }


@pytest.mark.unit
def test_metrics_append_record_keys_and_empty_report_count(monkeypatch, capsys, tmp_path):
    rec, _ = _metrics(monkeypatch, capsys, tmp_path, "", report_count="", extra=("test",))
    # backfill の重複判定は (date, ts)、集計は source で本番 run を選ぶ
    assert set(rec) == {
        "date",
        "ts",
        "source",
        "final_class",
        "report_count",
        "fallback_used",
        "pass1",
        "pass2",
        "clarity_pass",
        "lint",
        "line_states",
        "verification",
        "total_cost",
    }
    assert rec["source"] == "test"
    assert rec["report_count"] == 0
    assert len(rec["ts"]) == len("2026-11-02T05:00:00")


@pytest.mark.unit
def test_metrics_append_counts_only_verify_rows_that_ran(monkeypatch, capsys, tmp_path):
    stdin = "".join(
        f"VERIFY\t{v}\n"
        for v in (
            '{"supported":1,"ran":true}',
            '{"supported":2,"ran":true}',
            '{"supported":0,"ran":false}',
        )
    )
    rec, _ = _metrics(monkeypatch, capsys, tmp_path, stdin)
    assert rec["verification"]["lines_verified"] == 2
    assert rec["verification"]["supported"] == 3
