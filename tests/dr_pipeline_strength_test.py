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
    # 3 行 (非 JSON・非 object・cost_usd の無い行) が読めない。1 行目で数え止めず、行番号と理由を名指す
    assert err == (
        f"spend-gate: 3 unreadable line(s) in {ledger}: line 1 (not JSON), line 3 (not an object), "
        "line 4 (no cost_usd)\n"
    )


@pytest.mark.unit
@pytest.mark.parametrize(
    "row,reason",
    [
        ('{"date": "2026-11-02"}', "no cost_usd"),
        ('{"date": "2026-11-02", "cost_usd": null}', "no cost_usd"),
        # 偽値を 0 に読み替えない (`or 0` で "" / {} が 0 ドルになっていた)
        ('{"date": "2026-11-02", "cost_usd": ""}', "cost_usd is not a number"),
        ('{"date": "2026-11-02", "cost_usd": {}}', "cost_usd is not a number"),
    ],
    ids=["missing", "null", "empty-string", "empty-object"],
)
def test_spend_gate_row_without_cost_is_unreadable(monkeypatch, capsys, tmp_path, row, reason):
    # spend-add は必ず cost_usd を数で書く。無い行 (手で編集した台帳) を 0 ドルに数えると、その行の
    # 費用が累計から黙って消え、上限の判定が甘くなる
    ledger = _write(tmp_path, "l.jsonl", '{"date": "2026-11-02", "cost_usd": 1}\n' + row + "\n")
    rc, out, err = run_cmd(
        monkeypatch, capsys, ["spend-gate", ledger, "2026-11-02", "100", "10", "1"]
    )
    assert rc == 2
    assert out == ""
    assert err == f"spend-gate: 1 unreadable line(s) in {ledger}: line 2 ({reason})\n"


@pytest.mark.unit
@pytest.mark.parametrize(
    "row,reason",
    [
        ('{"cost_usd": 50}', "no date"),
        ('{"date": null, "cost_usd": 50}', "no date"),
        ('{"date": "", "cost_usd": 50}', "date is not YYYY-MM-DD"),
        ('{"date": 20261102, "cost_usd": 50}', "date is not YYYY-MM-DD"),
        ('{"date": "2026/11/02", "cost_usd": 50}', "date is not YYYY-MM-DD"),
        # \d は Unicode 数字にも一致する。全角・アラビア数字の date は月の接頭 (ASCII) と一致せず、
        # 検査を通したうえで累計から外れていた
        ('{"date": "２０２６-１１-０２", "cost_usd": 50}', "date is not YYYY-MM-DD"),
        ('{"date": "٢٠٢٦-١١-٠٢", "cost_usd": 50}', "date is not YYYY-MM-DD"),
    ],
    ids=["missing", "null", "empty", "int", "slashes", "fullwidth-digits", "arabic-indic-digits"],
)
def test_spend_gate_row_without_usable_date_is_unreadable(
    monkeypatch, capsys, tmp_path, row, reason
):
    # date で月・日に振り分けられない行は、どの累計にも入らず 0 ドルと同じになっていた ($50 が通った)
    ledger = _write(tmp_path, "l.jsonl", '{"date": "2026-11-02", "cost_usd": 1}\n' + row + "\n")
    rc, out, err = run_cmd(
        monkeypatch, capsys, ["spend-gate", ledger, "2026-11-02", "100", "10", "1"]
    )
    assert rc == 2
    assert out == ""
    assert err == f"spend-gate: 1 unreadable line(s) in {ledger}: line 2 ({reason})\n"


@pytest.mark.unit
@pytest.mark.parametrize(
    "cost,reason",
    [
        ("-50", "cost_usd is negative"),
        ('"-1"', "cost_usd is negative"),
        ("NaN", "cost_usd is not finite"),
        ("Infinity", "cost_usd is not finite"),
        ("-Infinity", "cost_usd is not finite"),
        ("1e999", "cost_usd is not finite"),
    ],
    ids=["negative", "negative-string", "nan", "inf", "minus-inf", "overflowing-literal"],
)
def test_spend_gate_negative_or_non_finite_cost_is_unreadable(
    monkeypatch, capsys, tmp_path, cost, reason
):
    # 負の費用は累計を減らして上限を緩める。NaN / inf は止まりはしたが log の金額が nan / inf になり、
    # どの行が原因か分からなかった。json.loads は NaN / Infinity を既定で受け付ける
    ledger = _write(
        tmp_path,
        "l.jsonl",
        f'{{"date": "2026-11-02", "cost_usd": 60}}\n{{"date": "2026-11-02", "cost_usd": {cost}}}\n',
    )
    rc, out, err = run_cmd(
        monkeypatch, capsys, ["spend-gate", ledger, "2026-11-02", "100", "100", "1"]
    )
    assert rc == 2
    assert out == ""
    assert err == f"spend-gate: 1 unreadable line(s) in {ledger}: line 2 ({reason})\n"


@pytest.mark.unit
def test_spend_gate_deeply_nested_line_is_rc2_not_traceback(monkeypatch, capsys, tmp_path):
    # json.loads は深い入れ子で RecursionError (ValueError でない) を出す。以前は traceback で rc 1 に
    # なり、billing.sh が「上限で止めた」と読んで理由を捨てていた。深さ 10^6 は python 3.13 / 3.14
    # (本番の homebrew) の両方で RecursionError になる (3.14 は 10^5 では通る)
    depth = 1_000_000
    ledger = _write(
        tmp_path,
        "l.jsonl",
        '{"date": "2026-11-02", "cost_usd": 1}\n' + "[" * depth + "]" * depth + "\n",
    )
    rc, out, err = run_cmd(
        monkeypatch, capsys, ["spend-gate", ledger, "2026-11-02", "100", "10", "1"]
    )
    assert rc == 2
    assert out == ""
    assert err == f"spend-gate: 1 unreadable line(s) in {ledger}: line 2 (too deeply nested)\n"


@pytest.mark.unit
def test_spend_gate_zero_cost_is_a_readable_row(monkeypatch, capsys, tmp_path):
    # 0 は報告された費用 (spend-add が total_cost_usd: 0 を記録する)。読めない行にしない
    ledger = _write(tmp_path, "l.jsonl", '{"date": "2026-11-02", "cost_usd": 0}\n')
    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["spend-gate", ledger, "2026-11-02", "100", "10", "1"]
    )
    assert rc == 0
    assert out == "ok\t0.00\t0.00\n"


@pytest.mark.unit
@pytest.mark.parametrize(
    "bad",
    [b"\xff", b'{"date": "2026-11-02", "line": "\xe3\x81", "cost_usd": 1}'],
    ids=["stray-byte", "truncated-multibyte-in-row"],
)
def test_spend_gate_non_utf8_line_is_rc2_with_line_number(monkeypatch, capsys, tmp_path, bad):
    # UTF-8 でない byte は台帳全体の UnicodeDecodeError (traceback で rc 1) にせず、その行を
    # 読めない行として rc 2。rc 1 は billing.sh が「上限で止めた」と読み、理由が log から消えていた
    ledger = tmp_path / "l.jsonl"
    ledger.write_bytes(
        b'{"date": "2026-11-02", "cost_usd": 1}\n'
        + bad
        + b'\n{"date": "2026-11-02", "cost_usd": 2}\n'
    )
    rc, out, err = run_cmd(
        monkeypatch, capsys, ["spend-gate", str(ledger), "2026-11-02", "100", "10", "1"]
    )
    assert rc == 2
    assert out == ""
    assert err == f"spend-gate: 1 unreadable line(s) in {ledger}: line 2 (not UTF-8)\n"


@pytest.mark.unit
@pytest.mark.parametrize(
    "cost", ['"abc"', '{"usd": 1}', "1" + "0" * 400], ids=["string", "object", "overflows-float"]
)
def test_spend_gate_non_numeric_cost_is_rc2(monkeypatch, capsys, tmp_path, cost):
    # float() で判定できない cost_usd は読めない行。巨大な整数は OverflowError で、以前は
    # 行ごとの except を素通りして traceback (rc 1 = 上限で止めたと読まれる) だった
    ledger = _write(tmp_path, "l.jsonl", f'{{"date": "2026-11-02", "cost_usd": {cost}}}\n')
    rc, out, err = run_cmd(
        monkeypatch, capsys, ["spend-gate", ledger, "2026-11-02", "100", "10", "1"]
    )
    assert rc == 2
    assert out == ""
    assert err == (
        f"spend-gate: 1 unreadable line(s) in {ledger}: line 1 (cost_usd is not a number)\n"
    )


@pytest.mark.unit
def test_spend_gate_names_at_most_five_unreadable_lines(monkeypatch, capsys, tmp_path):
    # 理由は billing.sh が log の 1 行に載せる。壊れた台帳で log を膨らませない
    ledger = _write(tmp_path, "l.jsonl", "x\n" * 7)
    rc, _, err = run_cmd(
        monkeypatch, capsys, ["spend-gate", ledger, "2026-11-02", "100", "10", "1"]
    )
    assert rc == 2
    assert err == (
        f"spend-gate: 7 unreadable line(s) in {ledger}: line 1 (not JSON), line 2 (not JSON), "
        "line 3 (not JSON), line 4 (not JSON), line 5 (not JSON), and 2 more\n"
    )


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
    # backfill の重複判定は (date, source が test か否か)、集計は source で本番 run を選ぶ
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
        "event_age_days",
        "total_cost",
    }
    assert rec["source"] == "test"
    assert rec["event_age_days"] is None  # EVENT 行の無い日 (H17)
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


# === report-lint (ctl-016): 当日レポートの決定論検査 ===

DAY = "2026-08-05"


def _report_text(n_sources, *, memo=True, length=1600):
    # length = 本文の字数 (body_chars: H1 の後〜末尾固定節の前、空白を除く)
    tail = "## 機会メモ\n- **何を**: x\n\n" if memo else ""
    tail += "## ソース\n" + "".join(
        f"- [s{i}](https://example.com/{i})\n" for i in range(n_sources)
    )
    return f"# T\n\n{'p' * length}\n\n{tail}"


def _lint(monkeypatch, capsys, report_dir, config):
    rc, out, err = run_cmd(monkeypatch, capsys, ["report-lint", str(report_dir), DAY, str(config)])
    return rc, json.loads(out), err


@pytest.mark.unit
@pytest.mark.parametrize(
    "config_text,n_sources,expected_soft",
    [
        # [report].min_sources が既定 5 を上書きする
        ("[report]\nmin_sources = 2\n", 2, []),
        ("[report]\nmin_sources = 2\n", 1, ["出典 URL 1 件 (< 2)"]),
        # [report] 節が無い・節はあるが key が無い・config が無い → 既定 5
        ("[general]\n", 5, []),
        ("[general]\n", 4, ["出典 URL 4 件 (< 5)"]),
        ("[report]\n", 4, ["出典 URL 4 件 (< 5)"]),
        (None, 4, ["出典 URL 4 件 (< 5)"]),
    ],
    ids=[
        "override-met",
        "override-short",
        "no-report-table-met",
        "no-report-table-short",
        "no-min-sources-key",
        "no-config-file",
    ],
)
def test_report_lint_min_sources_from_config(
    monkeypatch, capsys, tmp_path, config_text, n_sources, expected_soft
):
    config = tmp_path / "config.toml"
    if config_text is not None:
        config.write_text(config_text, encoding="utf-8")
    reports = tmp_path / "reports"
    reports.mkdir()
    (reports / f"{DAY}_akc_x.md").write_text(_report_text(n_sources), encoding="utf-8")
    rc, d, _ = _lint(monkeypatch, capsys, reports, config)
    assert rc == 0
    assert d["results"][0]["soft"] == expected_soft


@pytest.mark.unit
@pytest.mark.parametrize("length,short", [(1500, False), (1499, True)])
def test_report_lint_body_length_boundary(monkeypatch, capsys, tmp_path, length, short):
    # 本文長の soft は「1500 字未満」。ちょうど 1500 字は通す
    (tmp_path / f"{DAY}_akc_x.md").write_text(_report_text(5, length=length), encoding="utf-8")
    rc, d, _ = _lint(monkeypatch, capsys, tmp_path, CONFIG)
    assert rc == 0
    assert d["results"][0]["soft"] == ([f"本文 {length} 字 (< 1500)"] if short else [])


@pytest.mark.unit
def test_report_lint_result_shape(monkeypatch, capsys, tmp_path):
    # LINT の JSON は metrics.jsonl に入り、hard fail は log と notify に載る。形を固定する
    text = "# T\n\n本文だけ"
    (tmp_path / f"{DAY}_akc_bad.md").write_text(text, encoding="utf-8")
    thin = _report_text(2, memo=False, length=200)
    (tmp_path / f"{DAY}_akc_thin.md").write_text(thin, encoding="utf-8")
    rc, d, _ = _lint(monkeypatch, capsys, tmp_path, CONFIG)
    assert rc == 2
    assert d == {
        "date": DAY,
        "files": 2,
        "hard_fail": 1,
        "soft_fail": 2,
        "results": [
            {
                "file": f"{DAY}_akc_bad.md",
                "kind": "article",
                "hard": ["ソース節がない", "出典 URL が 0 件"],
                # 本文 = H1 の後の「本文だけ」(4 字)。file_chars はファイル全長
                "soft": ["必須節欠落: 機会メモ", "本文 4 字 (< 1500)"],
                "body_chars": 4,
                "file_chars": len(text),
                "body_headings": 0,
            },
            {
                "file": f"{DAY}_akc_thin.md",
                "kind": "article",
                "hard": [],
                "soft": ["出典 URL 2 件 (< 5)", "必須節欠落: 機会メモ", "本文 200 字 (< 1500)"],
                "body_chars": 200,
                "file_chars": len(thin),
                "body_headings": 0,
            },
        ],
    }


@pytest.mark.unit
def test_report_lint_soft_only_counts_one_per_file(monkeypatch, capsys, tmp_path):
    (tmp_path / f"{DAY}_akc_thin.md").write_text(_report_text(2), encoding="utf-8")
    rc, d, _ = _lint(monkeypatch, capsys, tmp_path, CONFIG)
    assert rc == 0
    assert (d["files"], d["hard_fail"], d["soft_fail"]) == (1, 0, 1)


@pytest.mark.unit
def test_report_lint_missing_dir_is_empty_pass(monkeypatch, capsys, tmp_path):
    rc, d, _ = _lint(monkeypatch, capsys, tmp_path / "no-such-dir", CONFIG)
    assert rc == 0
    assert d == {"date": DAY, "files": 0, "hard_fail": 0, "soft_fail": 0, "results": []}


@pytest.mark.unit
def test_report_lint_unreadable_entry_is_hard_and_rest_still_checked(monkeypatch, capsys, tmp_path):
    # 読めない entry (ここでは .md 名の dir) は hard。後ろの file の検査は続ける
    (tmp_path / f"{DAY}_akc_a-dir.md").mkdir()
    (tmp_path / f"{DAY}_akc_b-good.md").write_text(_report_text(5), encoding="utf-8")
    rc, d, _ = _lint(monkeypatch, capsys, tmp_path, CONFIG)
    assert rc == 2
    assert (d["files"], d["hard_fail"], d["soft_fail"]) == (2, 1, 0)
    bad, good = d["results"]
    assert set(bad) == {"file", "hard", "soft"}
    assert bad["file"] == f"{DAY}_akc_a-dir.md"
    assert len(bad["hard"]) == 1 and bad["hard"][0].startswith("read error: ")
    assert bad["soft"] == []
    assert good["file"] == f"{DAY}_akc_b-good.md" and good["hard"] == []


# === repo-activity: 直近の commit 件名 (呼1 の context に入る repo 由来の文字列) ===


def _repo(tmp_path, commits, config=()):
    """commits: [(subject, days_ago)] を古い順に commit した repo を返す。
    config: repo-local の git config [(key, value)] (repo 側の設定として残る)。"""
    import subprocess
    import time

    repo = tmp_path / "repo"
    repo.mkdir()
    env = {
        # 呼び出し元の GIT_* (git hook・rebase --exec が GIT_DIR を export する) を落とす — 残ると
        # git -C <tmp> init / config が実 repo の .git に当たる (2026-11-08 に core.bare = true が書かれた)
        **{k: v for k, v in os.environ.items() if not k.startswith("GIT_")},
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@example.invalid",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@example.invalid",
        # 運用者の global / system 設定 (hooksPath・署名) を効かせない
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
    }
    base = ["git", "-C", str(repo), "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"]

    def git(*a, extra_env=None):
        subprocess.run(
            [*base, *a], check=True, env={**env, **(extra_env or {})}, capture_output=True
        )

    git("init", "-q")
    for key, value in config:
        git("config", key, value)
    now = int(time.time())
    msg = tmp_path / "msg"
    for i, (subject, days_ago) in enumerate(commits):
        (repo / f"f{i}").write_text(str(i))
        git("add", ".")
        msg.write_text(subject, encoding="utf-8")
        stamp = f"{now - days_ago * 86400} +0000"
        git(
            "commit",
            "-q",
            "--cleanup=verbatim",
            "-F",
            str(msg),
            extra_env={"GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp},
        )
    return repo


def _activity(monkeypatch, capsys, repo, *extra):
    return run_cmd(monkeypatch, capsys, ["repo-activity", str(repo), *extra])


@pytest.mark.unit
def test_repo_activity_days_window_follows_flag(monkeypatch, capsys, tmp_path):
    repo = _repo(tmp_path, [("old change", 30), ("new change", 0)])
    rc, out, _ = _activity(monkeypatch, capsys, repo, "--days", "14")
    assert rc == 0
    assert out == "- new change\n"
    rc, out, _ = _activity(monkeypatch, capsys, repo, "--days", "60")
    assert rc == 0
    assert out == "- new change\n- old change\n"


@pytest.mark.unit
def test_repo_activity_invalid_days_is_usage_error(monkeypatch, capsys, tmp_path):
    rc, out, err = _activity(monkeypatch, capsys, tmp_path, "--days", "abc")
    assert rc == 64
    assert out == ""
    assert err == "repo-activity: invalid --days 'abc'\n"


@pytest.mark.unit
def test_repo_activity_without_git_is_empty(monkeypatch, capsys, tmp_path):
    # launchd の PATH に git が無くても line を止めない (空出力 + rc 0)
    repo = _repo(tmp_path, [("a change", 0)])
    monkeypatch.setenv("PATH", str(tmp_path / "empty-bin"))
    rc, out, _ = _activity(monkeypatch, capsys, repo)
    assert rc == 0
    assert out == ""


@pytest.mark.unit
def test_repo_activity_non_utf8_output_is_replaced(monkeypatch, capsys, tmp_path):
    # repo 側の i18n.logOutputEncoding が UTF-8 でないと git log は別の符号化で出す。
    # 復号できない byte は置換文字にして、line を落とさない
    repo = _repo(tmp_path, [("café subject", 0)], config=[("i18n.logOutputEncoding", "latin1")])
    rc, out, _ = _activity(monkeypatch, capsys, repo)
    assert rc == 0
    assert out == "- caf\N{REPLACEMENT CHARACTER} subject\n"


@pytest.mark.unit
def test_repo_activity_sanitizes_subject_exactly(monkeypatch, capsys, tmp_path):
    # 制御文字は空白に、連続空白は 1 つに、行頭の # (見出し) は外す。# 以外の先頭文字は残す
    repo = _repo(tmp_path, [("##Xcode   build\x07fix", 0)])
    rc, out, _ = _activity(monkeypatch, capsys, repo)
    assert rc == 0
    assert out == "- Xcode build fix\n"


@pytest.mark.unit
def test_repo_activity_skips_empty_subject_and_continues(monkeypatch, capsys, tmp_path):
    repo = _repo(tmp_path, [("older change", 0), ("###", 0)])
    rc, out, _ = _activity(monkeypatch, capsys, repo)
    assert rc == 0
    assert out == "- older change\n"


@pytest.mark.unit
def test_repo_activity_char_cap_is_inclusive(monkeypatch, capsys, tmp_path):
    # 1 行 = "- " + 件名 + 改行。20 行 x 100 字 = ちょうど上限 2000 字は全部出す
    subjects = [(f"c{i:02d} " + "x" * 93, 0) for i in range(20)]
    repo = _repo(tmp_path, subjects)
    rc, out, _ = _activity(monkeypatch, capsys, repo)
    assert rc == 0
    assert len(out.splitlines()) == 20
    assert len(out) == dr_pipeline.REPO_ACTIVITY_MAX_CHARS


@pytest.mark.unit
def test_repo_activity_char_cap_drops_line_that_would_exceed(monkeypatch, capsys, tmp_path):
    # 19 行 x 100 字 = 1900 字の後の 101 字の行は 2001 字になるので出さない
    subjects = [("o00 " + "x" * 94, 0)] + [(f"c{i:02d} " + "x" * 93, 0) for i in range(19)]
    repo = _repo(tmp_path, subjects)
    rc, out, _ = _activity(monkeypatch, capsys, repo)
    assert rc == 0
    assert len(out.splitlines()) == 19
    assert len(out) == 1900
    assert "- o00 " not in out


# === tracks / rotation-pick の行構築と、config 不正の診断 ===


@pytest.mark.unit
def test_tracks_ecosystem_line_before_repo_lines_keeps_all_rows(monkeypatch, capsys, tmp_path):
    # ecosystem line の行を出した後も、続く line の行を出し続ける (記述順は config 次第)
    cfg = _write(
        tmp_path,
        "c.toml",
        '[tracks.eco]\nmode = "ecosystem"\n'
        '[tracks.a]\n[[tracks.a.repos]]\nkey = "a"\ntarget_repo = "/r/a"\n'
        '[tracks.b]\n[[tracks.b.repos]]\nkey = "b"\ntarget_repo = "/r/b"\n',
    )
    rc, out, _ = run_cmd(monkeypatch, capsys, ["tracks", cfg])
    assert rc == 0
    assert out == "eco\teco\t\na\ta\t/r/a\nb\tb\t/r/b\n"


@pytest.mark.unit
def test_tracks_half_specified_repo_entry_is_a_config_error(monkeypatch, capsys, tmp_path):
    # key と target_repo の片方しか無い entry は行にも "None" の target_repo にもせず、config の
    # 誤りとして rc 1 (黙って捨てると line の repo が輪番から消える)。最初の欠けた entry を名指す
    cfg = _write(
        tmp_path,
        "c.toml",
        '[tracks.a]\n[[tracks.a.repos]]\nkey = "a"\n'
        '[[tracks.a.repos]]\ntarget_repo = "/r/x"\n'
        '[[tracks.a.repos]]\nkey = "a2"\ntarget_repo = "/r/a2"\n',
    )
    rc, out, err = run_cmd(monkeypatch, capsys, ["tracks", cfg])
    assert rc == 1
    assert out == ""
    assert err == (
        "[[tracks.a.repos]] entry 1 must set target_repo to a non-empty string, got None\n"
    )


@pytest.mark.unit
@pytest.mark.parametrize(
    "args",
    [
        ["tracks", "{cfg}"],
        ["rotation-pick", "{cfg}", "2026-11-02"],
        ["line-brief", "{cfg}", "authorship"],
        ["template-path", "{cfg}", "authorship"],
        ["past-themes", "{past}", "{cfg}"],
    ],
    ids=lambda a: a[0],
)
def test_config_schema_error_reaches_the_log(monkeypatch, capsys, tmp_path, args):
    # daily-research.sh はどの呼び出しも stderr を LOG_FILE に足す。旧 schema の config で朝を
    # 迎えたとき、移行の手順が書かれた 1 行が log に残る
    cfg = str(FIXTURES / "config-old-schema.toml")
    past = str(tmp_path / "none.json")
    argv = [a.format(cfg=cfg, past=past) for a in args]
    rc, out, err = run_cmd(monkeypatch, capsys, argv)
    assert rc == 1
    assert out == ""
    assert err == (
        "config uses the legacy schema: target_repo directly under [tracks.authorship]. "
        "Migrate to [[tracks.authorship.repos]] entries (see config.example.toml)\n"
    )


@pytest.mark.unit
def test_rotation_pick_no_lines_message(monkeypatch, capsys):
    rc, out, err = run_cmd(
        monkeypatch,
        capsys,
        ["rotation-pick", str(FIXTURES / "config-no-tracks.toml"), "2026-11-02"],
    )
    assert rc == 1 and out == ""
    assert err == "rotation-pick: no lines in config\n"


# === past-themes: 呼1 のプロンプトに入る問いの履歴 ===

PAST_HEADER = (
    "=== 過去テーマ履歴 (line 別直近 10 件、問い単位) ===\n"
    "各行は「問い — 答えの範囲 (answer_scope)」。判定は問い単位で行う:\n"
    "- 同じ問い + 同じ答え = 再選定禁止\n"
    "- 同じ問い + 新証拠 = 更新として可 (何が新しい証拠かを本文に書く)\n"
    "- 同じ topic + 別の問い = 可\n"
    "\n"
)


def _topics_file(path, topics):
    path.write_text(json.dumps({"version": 1, "topics": topics}), encoding="utf-8")
    return str(path)


@pytest.mark.unit
def test_past_themes_default_paths_are_cwd_files(monkeypatch, capsys, tmp_path):
    # daily-research.sh は引数なしで呼ぶ (cwd = PROJECT_DIR の past_topics.json と config.toml)
    (tmp_path / "config.toml").write_text(pathlib.Path(CONFIG).read_text(), encoding="utf-8")
    _topics_file(
        tmp_path / "past_topics.json",
        [{"track": "authorship", "date": "2026-09-01", "question": "Q?"}],
    )
    monkeypatch.chdir(tmp_path)
    rc, out, _ = run_cmd(monkeypatch, capsys, ["past-themes"])
    assert rc == 0
    assert out == PAST_HEADER + "Track: authorship\n  - 2026-09-01 Q?\n\n"


@pytest.mark.unit
def test_past_themes_explicit_past_path_wins_over_cwd(monkeypatch, capsys, tmp_path):
    (tmp_path / "config.toml").write_text(pathlib.Path(CONFIG).read_text(), encoding="utf-8")
    _topics_file(tmp_path / "past_topics.json", [{"track": "authorship", "question": "DECOY"}])
    (tmp_path / "sub").mkdir()
    real = _topics_file(tmp_path / "sub" / "p.json", [{"track": "authorship", "question": "REAL"}])
    monkeypatch.chdir(tmp_path)
    rc, out, _ = run_cmd(monkeypatch, capsys, ["past-themes", real])
    assert rc == 0
    assert "REAL" in out and "DECOY" not in out


@pytest.mark.unit
def test_past_themes_file_without_topics_is_header_only(monkeypatch, capsys, tmp_path):
    past = tmp_path / "p.json"
    past.write_text('{"version": 1}', encoding="utf-8")
    rc, out, _ = run_cmd(monkeypatch, capsys, ["past-themes", str(past), CONFIG])
    assert rc == 0
    assert out == PAST_HEADER


@pytest.mark.unit
def test_past_themes_entry_rendering(monkeypatch, capsys, tmp_path):
    past = _topics_file(
        tmp_path / "p.json",
        [
            {"track": "authorship", "date": "2026-09-02", "question": "Q2", "answer_scope": "S2"},
            {"track": "authorship", "question": "Q-undated"},
            {"track": "authorship", "date": "2026-09-01", "title": "T1"},
            # 問いも題も空の entry (問いを残さなかった run) は履歴に出さない
            {"track": "authorship", "date": "2026-09-03", "title": "", "question": ""},
        ],
    )
    rc, out, _ = run_cmd(monkeypatch, capsys, ["past-themes", past, CONFIG])
    assert rc == 0
    # date 昇順 (date 無しは先頭、表示は ?)。answer_scope があるときだけ " — " を付ける。
    # aliases を持たない line の見出しに「旧 track」注記を付けない
    assert out == PAST_HEADER + (
        "Track: authorship\n  - ? Q-undated\n  - 2026-09-01 T1\n  - 2026-09-02 Q2 — S2\n\n"
    )


@pytest.mark.unit
def test_past_themes_keeps_latest_ten_per_line(monkeypatch, capsys, tmp_path):
    days = [7, 1, 11, 3, 9, 5, 2, 10, 4, 8, 6]
    past = _topics_file(
        tmp_path / "p.json",
        [{"track": "authorship", "date": f"2026-09-{d:02d}", "question": f"q{d}"} for d in days],
    )
    rc, out, _ = run_cmd(monkeypatch, capsys, ["past-themes", past, CONFIG])
    assert rc == 0
    lines = out[len(PAST_HEADER) :].splitlines()
    assert lines[0] == "Track: authorship"
    assert lines[1:-1] == [f"  - 2026-09-{d:02d} q{d}" for d in range(2, 12)]


@pytest.mark.unit
def test_past_themes_truncates_at_120_chars(monkeypatch, capsys, tmp_path):
    past = _topics_file(
        tmp_path / "p.json",
        [
            {"track": "authorship", "date": "2026-09-01", "question": "a" * 120},
            {
                "track": "authorship",
                "date": "2026-09-02",
                "question": "b" * 121,
                "answer_scope": "s" * 121,
            },
        ],
    )
    rc, out, _ = run_cmd(monkeypatch, capsys, ["past-themes", past, CONFIG])
    assert rc == 0
    lines = out[len(PAST_HEADER) :].splitlines()
    # ちょうど 120 字は省略記号なし。121 字は 120 字 + 「…」。answer_scope は 120 字で切る
    assert lines[1] == "  - 2026-09-01 " + "a" * 120
    assert lines[2] == "  - 2026-09-02 " + "b" * 120 + "…" + " — " + "s" * 120


# === line-brief: 呼1 のプロンプトに入る line 定義 ===
# プロトコルは「Line 定義」「選定後に読む候補」「自己シグナル」「Step 3b」をこの出力の名前で指す。
# 文言を変えるときはプロトコル側の参照と合わせてここを直す。


@pytest.mark.unit
def test_line_brief_repo_line_exact(monkeypatch, capsys):
    rc, out, _ = run_cmd(monkeypatch, capsys, ["line-brief", CONFIG, "akc"])
    assert rc == 0
    assert out == (
        "## Line 定義 (config)\n"
        "\n"
        "- name: AKC Line\n"
        "- focus: AKC line focus\n"
        "- 探索の起点 (sources):\n"
        "  - fixture-source-a\n"
        "  - fixture-source-b\n"
        "- 自己シグナル (自己汚染ガード — これらに合致する成果物を「外部シグナル」\n"
        "  として数えない。第三者による言及・採用の観測は正当):\n"
        "  - github.com/example-author\n"
        "  - Example Author\n"
        "\n"
        "## 選定後に読む候補 (Step 3b)\n"
        "\n"
        "テーマ (問い) を選んだ後、含意の前提確認に関係するものだけを読む。\n"
        "存在しないものは skip してよい。\n"
        "- .notes/TASKS.md\n"
        "- docs/inspiration.md\n"
    )


@pytest.mark.unit
def test_line_brief_ecosystem_line_exact(monkeypatch, capsys):
    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["line-brief", str(FIXTURES / "config-ecosystem.toml"), "eco"]
    )
    assert rc == 0
    assert out == (
        "## Line 定義 (config)\n"
        "\n"
        "- mode: ecosystem (接地 repo なし — 観測対象は外部エコシステムの変化そのもの)\n"
        "- name: Ecosystem Line\n"
        "- focus: Ecosystem line focus\n"
        "- 探索の起点 (sources):\n"
        "  - fixture-eco-source\n"
        "- 自己シグナル (自己汚染ガード — これらに合致する成果物を「外部シグナル」\n"
        "  として数えない。第三者による言及・採用の観測は正当):\n"
        "  - github.com/example-author\n"
    )


@pytest.mark.unit
def test_line_brief_without_general_table(monkeypatch, capsys, tmp_path):
    cfg = _write(
        tmp_path,
        "c.toml",
        '[tracks.a]\nname = "A"\nfocus = "F"\n[[tracks.a.repos]]\nkey = "a"\ntarget_repo = "/r"\n',
    )
    rc, out, _ = run_cmd(monkeypatch, capsys, ["line-brief", cfg, "a"])
    assert rc == 0
    assert out == "## Line 定義 (config)\n\n- name: A\n- focus: F\n"
