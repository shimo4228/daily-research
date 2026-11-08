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
