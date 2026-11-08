"""呼3 (照合監査、ADR-0020) の決定論部分の単体テスト。

SH は claude を 2 段で呼び、dr_pipeline.py の audit-* が prompt の組み立て・応答の解析・状態
(state/<line>/runs/<date>.audit.json)・置き換えの適用を持つ。モデルはノートを書かない — 両段が
食い違いとした候補 (confirmed) だけを audit-apply が _audit_replace の規則で置き換える。ここが検査する
invariant:
- 置き換えは本文にちょうど 1 回現れる文だけ。frontmatter・題・機会メモ・ソース節は変わらない
- 置き換えはノート全体の URL・link 先・強調と inline code の対・見出しを変えない。実行・埋め込み・HTML になる
  記号と見えない文字を足さない。文の最小長と編集距離の上限がある。空・改行の増減は拒否
- 第 2 段の prompt に第 1 段の理由と正しい値は入らない
- どの段の失敗でもノートは呼2 の後のまま (audit-apply は常に rc 0)
"""

import io
import json
import os
import sys

import dr_pipeline
import pytest

NOTE = """---
date: 2026-11-07
kind: article
---

# 監査のテスト

報告書は 2026-10-01 に欧州の 3 か国で公開された。
調査は [観察研究](https://example.com/study) として行われ、参加者は 120 人だった。
同じ文が 2 回ある。
同じ文が 2 回ある。
第 2 四半期の売上は前年より伸びた（https://example.com/q2）。
締切の話はこのノートでは扱わない。

## 機会メモ

- 公募の締切は 2026-12-01（失効日 2026-12-01）。

## ソース

- [報告書](https://example.com/report) 欧州の 3 か国の資料
"""

S_REPORT = "報告書は 2026-10-01 に欧州の 3 か国で公開された。"
S_STUDY = "調査は [観察研究](https://example.com/study) として行われ、参加者は 120 人だった。"
S_Q2 = "第 2 四半期の売上は前年より伸びた（https://example.com/q2）。"


def run_cmd(monkeypatch, capsys, args, stdin=""):
    monkeypatch.setattr(sys, "stdin", io.StringIO(stdin))
    rc = dr_pipeline.main(args)
    out, err = capsys.readouterr()
    return rc, out, err


def claude_json(final_text, cost=0.2, turns=10):
    return json.dumps(
        {
            "type": "result",
            "subtype": "success",
            "is_error": False,
            "total_cost_usd": cost,
            "num_turns": turns,
            "result": final_text,
        },
        ensure_ascii=False,
    )


def disc(sentence, replacement, url="https://example.com/report", confidence="high", **kw):
    return {
        "note_sentence": sentence,
        "claim": "c",
        "source_quote": "q",
        "url": url,
        "correct_value": "v",
        "replacement": replacement,
        "type": "scope",
        "confidence": confidence,
        "drift": False,
        **kw,
    }


def stage1_text(discrepancies, claims=12, supported=10, unverifiable=None):
    body = {
        "note": "n.md",
        "claims_checked": claims,
        "supported": supported,
        "unverifiable": unverifiable
        if unverifiable is not None
        else [{"sentence": "s", "why": "w"}],
        "discrepancies": discrepancies,
    }
    return "監査の結果:\n```json\n" + json.dumps(body, ensure_ascii=False) + "\n```\n"


def stage1(monkeypatch, capsys, tmp_path, discrepancies, cls="OK", raw=None):
    path = tmp_path / "a.audit.json"
    stdin = raw if raw is not None else claude_json(stage1_text(discrepancies))
    rc, out, err = run_cmd(
        monkeypatch, capsys, ["audit-stage1", str(path), "2026-11-07", cls], stdin=stdin
    )
    assert rc == 0, err
    return path, out.split(), json.loads(path.read_text())


def confirm(monkeypatch, capsys, path, cid, verdict="contradicts", cls="OK", raw=None):
    text = json.dumps(
        {"verdict": verdict, "parts": [{"claim": "c", "source_quote": "sq"}], "url_read": "u"}
    )
    stdin = raw if raw is not None else claude_json(text, cost=0.05, turns=4)
    return run_cmd(monkeypatch, capsys, ["audit-confirm-record", str(path), cid, cls], stdin=stdin)


def apply(monkeypatch, capsys, tmp_path, path, note_text=NOTE):
    note = tmp_path / "note.md"
    if note_text is not None:
        note.write_text(note_text)
    pre = tmp_path / "pre-audit" / "2026-11-07.md"
    rc, out, err = run_cmd(monkeypatch, capsys, ["audit-apply", str(path), str(note), str(pre)])
    assert rc == 0, err
    lines = out.splitlines()
    return json.loads(lines[0]), lines[1:], note, pre


# === _audit_replace: 置き換えの規則 ===


@pytest.mark.unit
def test_replace_once_in_body_keeps_fixed_sections():
    repl = "報告書は 2026-10-01 に欧州の 4 か国で公開された。"
    new, why = dr_pipeline._audit_replace(NOTE, S_REPORT, repl)
    assert why is None
    assert new == NOTE.replace(S_REPORT, repl, 1)
    assert dr_pipeline._note_parts(new) == dr_pipeline._note_parts(NOTE)
    # ソース節の「欧州の 3 か国」は本文の外 — 残る
    assert "欧州の 3 か国の資料" in new


@pytest.mark.unit
@pytest.mark.parametrize(
    ("sentence", "replacement", "reason"),
    [
        (S_REPORT, "", "empty"),
        (S_REPORT, "  \n", "empty"),
        (S_REPORT, S_REPORT, "unchanged"),
        (S_REPORT, "報告書は\n欧州で公開された。", "newline"),
        (S_REPORT, "報告書は\t欧州で公開された。", "control"),
        (S_Q2, "第 2 四半期の売上は前年より伸びた。", "url_changed"),
        (S_Q2, "第 2 四半期の売上は伸びた（https://example.com/other）。", "url_changed"),
        (
            S_STUDY,
            "調査は観察研究 https://example.com/study として行われ、参加者は 120 人だった。",
            "link_changed",
        ),
        (
            S_REPORT,
            S_REPORT + "これは訂正の範囲を超えて段落を書き足すための長い追記で、" * 3,
            "edit_distance",
        ),
        ("存在しない文。", "直した文。", "not_found"),
        ("欧州の 3 か国の資料", "欧州の 4 か国の資料", "outside_body"),
        ("公募の締切は 2026-12-01", "公募の締切は 2026-12-15", "outside_body"),
        ("kind: article", "kind: brief", "outside_body"),
        ("# 監査のテスト", "# 監査の題", "outside_body"),
        ("同じ文が 2 回ある。", "同じ文が 1 回ある。", "ambiguous"),
        # 1 字の断片で語を差し替える
        ("売", "買", "short"),
        (S_REPORT, S_REPORT.replace("報告書は", "報告書は\x85"), "control"),
        (S_REPORT, S_REPORT.replace("3", "4​"), "invisible"),
        (S_REPORT, S_REPORT.replace("報告書", "‮報告書"), "invisible"),
        # vault で実行・埋め込み・HTML になる書式を足す
        (S_REPORT, S_REPORT.replace("3", "`$=dv.x`"), "markup"),
        (S_REPORT, S_REPORT.replace("3", "$=dv.x"), "markup"),
        (S_REPORT, S_REPORT.replace("3", "<img src=x>"), "markup"),
        (S_REPORT, S_REPORT.replace("3", "&#60;b&#62;"), "markup"),
        (S_REPORT, S_REPORT.replace("3", "[[秘密]]"), "markup"),
        (S_REPORT, S_REPORT.replace("3", "![[x]]"), "markup"),
        (S_REPORT, S_REPORT.replace("3", "%% x %%"), "markup"),
        (S_STUDY, S_STUDY.replace(") として", ")<!----> として"), "markup"),
        # URL は大文字の scheme でも数え、link 先のすり替えも URL の変化として止める
        (S_REPORT, S_REPORT.replace("欧州の 3 か国", "HTTPS://evil.example"), "url_changed"),
        (S_STUDY, S_STUDY.replace("https://example.com/", "HTTPS://exampl.com/"), "url_changed"),
        # 断片が link をまたぐ: [ を外すと URL は残っても link が壊れる
        ("調査は [観察研究](https://exa", "調査は 観察研究 (https://exa", "link_changed"),
        # 本文に固定節と同じ見出しを作る (このノートは機会メモ・ソースの両節を持つ)
        ("締切の話はこのノートでは扱わない。", "## 機会メモ", "heading_changed"),
        ("締切の話はこのノートでは扱わない。", "## ソース", "heading_changed"),
    ],
)
def test_replace_rejects_with_named_reason(sentence, replacement, reason):
    new, why = dr_pipeline._audit_replace(NOTE, sentence, replacement)
    assert (new, why) == (None, reason)


@pytest.mark.unit
@pytest.mark.parametrize(
    ("line", "sentence", "replacement", "reason"),
    [
        # 対の片方だけを外す
        (
            "報告書は **2026-10-01** に欧州の 3 か国で公開された。",
            "**2026-10-01** に欧州の 3 か国",
            "2026-10-01** に欧州の 4 か国",
            "emphasis_changed",
        ),
        (
            "`v1.2` は 2026-10-01 に公開された版である。",
            "`v1.2` は 2026-10-01 に公開された",
            "v1.2` は 2026-10-02 に公開された",
            "emphasis_changed",
        ),
        # 元からある & を使い回して HTML エンティティで URL を隠す (& の数は増えない)
        (
            "報告書は A &amp; B 社が 2026-10-01 に公開した資料である。",
            "報告書は A &amp; B 社が 2026-10-01 に公開した",
            "報告書は https:&#47;/e.x 社が 2026-10-01 に公開した",
            "url_changed",
        ),
        # 本文の見出しを固定節の見出しに変える: 見出し行の数は同じでも、固定節と同じ見出しが 2 つになる
        (
            "## ソースの読み方について補足",
            "## ソースの読み方について補足",
            "## ソース",
            "heading_changed",
        ),
    ],
)
def test_replace_compares_the_whole_note(line, sentence, replacement, reason):
    note = NOTE.replace(S_REPORT, line)
    new, why = dr_pipeline._audit_replace(note, sentence, replacement)
    assert (new, why) == (None, reason)


@pytest.mark.unit
def test_replace_that_would_create_a_fixed_section_is_rejected():
    note = NOTE.replace("## 機会メモ\n\n- 公募の締切は 2026-12-01（失効日 2026-12-01）。\n\n", "")
    new, why = dr_pipeline._audit_replace(note, "締切の話はこのノートでは扱わない。", "## 機会メモ")
    assert (new, why) == (None, "heading_changed")


@pytest.mark.unit
def test_replace_minimum_sentence_length():
    s = "欧州の 3 か国で公開された。"
    assert len(s) == dr_pipeline.AUDIT_SENTENCE_MIN
    assert dr_pipeline._audit_replace(NOTE, s, s.replace("3", "4"))[1] is None
    assert dr_pipeline._audit_replace(NOTE, s[1:], s[1:].replace("3", "4"))[1] == "short"


@pytest.mark.unit
def test_replace_edit_cap_scales_with_the_sentence():
    # 短い文は AUDIT_EDIT_MIN 字まで書き換えられる (限定を書き足す訂正)
    short = S_REPORT
    assert len(short) * dr_pipeline.AUDIT_EDIT_RATIO < dr_pipeline.AUDIT_EDIT_MIN
    ok = short[:-1] + "（" + "あ" * (dr_pipeline.AUDIT_EDIT_MIN - 2) + "）。"
    assert dr_pipeline._audit_replace(NOTE, short, ok)[1] is None
    over = short[:-1] + "（" + "あ" * (dr_pipeline.AUDIT_EDIT_MIN - 1) + "）。"
    assert dr_pipeline._audit_replace(NOTE, short, over)[1] == "edit_distance"
    # 長い文は字数 × AUDIT_EDIT_RATIO まで。置き換え (挿入でなく) も 1 字 1 つに数える
    long_s = "長" * 200 + "。"
    note = NOTE.replace(S_REPORT, long_s)
    cap = int(len(long_s) * dr_pipeline.AUDIT_EDIT_RATIO)
    ok = "短" * cap + long_s[cap:]
    assert dr_pipeline._audit_replace(note, long_s, ok)[1] is None
    over = "短" * (cap + 1) + long_s[cap + 1 :]
    assert dr_pipeline._audit_replace(note, long_s, over)[1] == "edit_distance"


@pytest.mark.unit
@pytest.mark.parametrize(
    ("a", "b", "cap", "dist"),
    [
        ("kitten", "sitting", 10, 3),
        ("", "abc", 10, 3),
        ("abc", "abc", 0, 0),
        ("abcdef", "uvwxyz", 3, 4),  # cap を超えたら cap + 1
        ("a", "abcdef", 2, 3),  # 長さの差だけで cap を超える
    ],
)
def test_edit_distance(a, b, cap, dist):
    assert dr_pipeline._edit_distance(a, b, cap) == dist


@pytest.mark.unit
def test_replace_keeps_percent_and_existing_markup_counts():
    # 元からある記号の数を増やさない訂正は通る (割合の訂正・リンクの文言の訂正)
    note = NOTE.replace(S_REPORT, "報告書は回答者の 52% が 2026-10-01 に同意したとした。")
    s = "報告書は回答者の 52% が 2026-10-01 に同意したとした。"
    new, why = dr_pipeline._audit_replace(note, s, s.replace("52%", "48%"))
    assert why is None and "48%" in new


@pytest.mark.unit
def test_replace_keeps_the_markdown_link_when_only_the_text_changes():
    repl = "調査は [観察研究](https://example.com/study) として行われ、参加者は 210 人だった。"
    new, why = dr_pipeline._audit_replace(NOTE, S_STUDY, repl)
    assert why is None and repl in new and S_STUDY not in new


# === audit-stage1: 第 1 段の応答の解析と候補の選別 ===


@pytest.mark.unit
def test_stage1_records_counts_and_prints_pending_ids(monkeypatch, capsys, tmp_path):
    path, ids, st = stage1(
        monkeypatch,
        capsys,
        tmp_path,
        [disc(S_REPORT, "x"), disc(S_Q2, "y", confidence="medium")],
    )
    assert ids == ["D1", "D2"]
    assert st["ran"] is True and st["reason"] is None
    assert (st["claims"], st["supported"], st["unverifiable"], st["invalid"]) == (12, 10, 1, 0)
    assert st["stage1"] == {"class": "OK", "cost": 0.2, "turns": 10}
    assert st["date"] == "2026-11-07"
    assert [c["status"] for c in st["candidates"]] == ["pending", "pending"]
    assert oct(os.stat(path).st_mode & 0o777) == oct(0o600)


@pytest.mark.unit
def test_stage1_counts_broken_candidates_as_invalid(monkeypatch, capsys, tmp_path):
    bad = [
        "not a dict",
        disc("", "x"),
        disc(S_REPORT, "x", url="javascript:alert(1)"),
        disc(S_REPORT, "x", url="https://example.com/ a"),
        disc("あ" * (dr_pipeline.AUDIT_SENTENCE_MAX + 1), "x"),
        {"url": "https://example.com/"},
    ]
    _, ids, st = stage1(monkeypatch, capsys, tmp_path, [*bad, disc(S_Q2, "y")])
    assert st["invalid"] == len(bad)
    assert ids == ["D7"]  # id は discrepancies の位置 (1 始まり) — invalid を詰めない


@pytest.mark.unit
def test_stage1_normalizes_fields(monkeypatch, capsys, tmp_path):
    raw = disc(S_REPORT, 42, confidence="certain", claim="a\x07b" + "c" * 600)
    _, _, st = stage1(monkeypatch, capsys, tmp_path, [raw])
    c = st["candidates"][0]
    assert c["replacement"] == "" and c["confidence"] == "low"
    assert c["claim"].startswith("a b") and len(c["claim"]) == dr_pipeline.AUDIT_FIELD_MAX
    assert c["confirm"] is None and c["drift"] is False


@pytest.mark.unit
def test_stage1_skips_drift_duplicates_and_over_cap_in_confidence_order(
    monkeypatch, capsys, tmp_path
):
    n = dr_pipeline.AUDIT_MAX_CONFIRM
    many = [disc(f"文 {i} 。", "x", confidence="low") for i in range(n)]
    many.append(disc("高い文。", "x", confidence="high"))
    many.append(disc("高い文。", "x", confidence="high"))  # 同じ文の 2 件目
    many.append(disc("変わった文。", "x", confidence="high", drift=True))
    _, ids, st = stage1(monkeypatch, capsys, tmp_path, many)
    by_id = {c["id"]: c for c in st["candidates"]}
    assert len(ids) == n and f"D{n + 1}" in ids  # high が先に枠を取る
    assert (by_id[f"D{n + 2}"]["status"], by_id[f"D{n + 2}"]["reason"]) == ("skipped", "duplicate")
    assert (by_id[f"D{n + 3}"]["status"], by_id[f"D{n + 3}"]["reason"]) == ("skipped", "drift")
    over = [c for c in st["candidates"] if c["reason"] == "over_cap"]
    assert len(over) == 1 and over[0]["confidence"] == "low"


@pytest.mark.unit
@pytest.mark.parametrize(
    ("cls", "raw", "reason"),
    [
        ("E_TRANSIENT", "", "E_TRANSIENT"),
        ("E_PROMPT", "", "E_PROMPT"),
        ("OK", "not json", "parse"),
        ("OK", None, "parse"),  # JSON の result だが最終メッセージに JSON が無い
        ("OK", "[1, 2]", "parse"),
    ],
)
def test_stage1_failure_is_ran_false_with_reason(monkeypatch, capsys, tmp_path, cls, raw, reason):
    raw = claude_json("監査できなかった。") if raw is None else raw
    _, ids, st = stage1(monkeypatch, capsys, tmp_path, [], cls=cls, raw=raw)
    assert ids == [] and st["ran"] is False and st["reason"] == reason
    assert st["candidates"] == []


@pytest.mark.unit
def test_stage1_reads_braces_without_fence_and_stream_arrays(monkeypatch, capsys, tmp_path):
    body = {"claims_checked": 3, "supported": 3, "unverifiable": 2, "discrepancies": []}
    final = "結果は " + json.dumps(body) + " です"
    raw = json.dumps([{"type": "system"}, json.loads(claude_json(final))])
    _, ids, st = stage1(monkeypatch, capsys, tmp_path, [], raw=raw)
    assert ids == [] and st["ran"] is True
    assert (st["claims"], st["unverifiable"]) == (3, 2)


@pytest.mark.unit
def test_stage1_without_discrepancies_list_is_a_parse_failure(monkeypatch, capsys, tmp_path):
    raw = claude_json('```json\n{"claims_checked": 3}\n```')
    _, _, st = stage1(monkeypatch, capsys, tmp_path, [], raw=raw)
    assert st["ran"] is False and st["reason"] == "parse"


@pytest.mark.unit
def test_stage1_unwritable_state_is_rc1(monkeypatch, capsys, tmp_path):
    rc, out, err = run_cmd(
        monkeypatch,
        capsys,
        ["audit-stage1", str(tmp_path / "missing-dir" / "a.json"), "2026-11-07", "OK"],
        stdin=claude_json(stage1_text([disc(S_REPORT, "x")])),
    )
    assert rc == 1 and out == "" and "cannot write" in err


# === audit-confirm-prompt / audit-confirm-record: 第 2 段 ===


@pytest.mark.unit
def test_confirm_prompt_carries_only_sentence_url_and_date(monkeypatch, capsys, tmp_path):
    raw = disc(S_REPORT, "置き換え文", claim="第1段の理由", correct_value="第1段の正しい値")
    path, _, _ = stage1(monkeypatch, capsys, tmp_path, [raw])
    rc, out, _ = run_cmd(monkeypatch, capsys, ["audit-confirm-prompt", str(path), "D1"])
    assert rc == 0
    assert S_REPORT in out and "https://example.com/report" in out and "2026-11-07" in out
    for leaked in ("第1段の理由", "第1段の正しい値", "置き換え文"):
        assert leaked not in out


@pytest.mark.unit
@pytest.mark.parametrize("cid", ["D9", "X1", "../D1", ""])
def test_confirm_prompt_without_pending_candidate_is_rc1(monkeypatch, capsys, tmp_path, cid):
    path, _, _ = stage1(monkeypatch, capsys, tmp_path, [disc(S_REPORT, "x")])
    rc, out, _ = run_cmd(monkeypatch, capsys, ["audit-confirm-prompt", str(path), cid])
    assert rc == 1 and out == ""


@pytest.mark.unit
@pytest.mark.parametrize(
    ("verdict", "cls", "raw", "status", "reason"),
    [
        ("contradicts", "OK", None, "confirmed", None),
        ("consistent", "OK", None, "not_confirmed", "consistent"),
        ("unverifiable", "OK", None, "not_confirmed", "unverifiable"),
        ("maybe", "OK", None, "confirm_failed", "parse"),
        ("contradicts", "E_TRANSIENT", None, "confirm_failed", "E_TRANSIENT"),
        ("contradicts", "OK", "garbage", "confirm_failed", "parse"),
    ],
)
def test_confirm_record_sets_status(
    monkeypatch, capsys, tmp_path, verdict, cls, raw, status, reason
):
    path, _, _ = stage1(monkeypatch, capsys, tmp_path, [disc(S_REPORT, "x")])
    rc, _, err = confirm(monkeypatch, capsys, path, "D1", verdict=verdict, cls=cls, raw=raw)
    assert rc == 0, err
    st = json.loads(path.read_text())
    c = st["candidates"][0]
    assert (c["status"], c["reason"]) == (status, reason)
    assert st["confirm"]["calls"] == 1
    if status != "confirm_failed":
        assert c["confirm"] == {"verdict": verdict, "source_quote": "sq", "url_read": "u"}


@pytest.mark.unit
def test_confirm_record_sums_cost_and_refuses_a_second_record(monkeypatch, capsys, tmp_path):
    path, _, _ = stage1(monkeypatch, capsys, tmp_path, [disc(S_REPORT, "x"), disc(S_Q2, "y")])
    assert confirm(monkeypatch, capsys, path, "D1")[0] == 0
    assert confirm(monkeypatch, capsys, path, "D2", verdict="consistent")[0] == 0
    assert confirm(monkeypatch, capsys, path, "D1")[0] == 1  # もう pending でない
    st = json.loads(path.read_text())
    assert st["confirm"] == {"calls": 2, "cost": 0.1, "turns": 8}


@pytest.mark.unit
def test_confirm_record_with_broken_state_is_rc1(monkeypatch, capsys, tmp_path):
    path = tmp_path / "a.json"
    for text in ("not json", '{"version": 99, "candidates": []}', '{"version": 1}'):
        path.write_text(text)
        rc, _, err = confirm(monkeypatch, capsys, path, "D1")
        assert rc == 1 and "no pending candidate" in err


# === audit-apply: 適用・写し・AUDIT 行 ===


def confirmed_state(monkeypatch, capsys, tmp_path, discs, verdicts):
    path, ids, _ = stage1(monkeypatch, capsys, tmp_path, discs)
    for cid, v in zip(ids, verdicts, strict=True):
        assert confirm(monkeypatch, capsys, path, cid, verdict=v)[0] == 0
    return path


@pytest.mark.unit
def test_apply_replaces_confirmed_only_and_writes_pre_copy(monkeypatch, capsys, tmp_path):
    fixed = "報告書は 2026-10-01 に欧州の 4 か国で公開された。"
    path = confirmed_state(
        monkeypatch,
        capsys,
        tmp_path,
        [
            disc(S_REPORT, fixed),
            disc("同じ文が 2 回ある。", "同じ文が 1 回ある。"),
            disc(S_Q2, "第 2 四半期の売上は前年より減った（https://example.com/q2）。"),
        ],
        ["contradicts", "contradicts", "consistent"],
    )
    summary, warns, note, pre = apply(monkeypatch, capsys, tmp_path, path)
    assert note.read_text() == NOTE.replace(S_REPORT, fixed, 1)
    assert pre.read_text() == NOTE
    assert oct(os.stat(pre).st_mode & 0o777) == oct(0o644)
    assert summary == {
        "ran": True,
        "reason": None,
        "claims": 12,
        "supported": 10,
        "unverifiable": 1,
        "invalid": 0,
        "candidates": 3,
        "confirmed": 2,
        "applied": 1,
        "rejected": 1,
        "confirm_calls": 3,
        "turns": 10,
        "confirm_turns": 12,
        "cost": 0.35,
    }
    assert len(warns) == 1 and "D2" in warns[0] and "ambiguous" in warns[0]
    st = json.loads(path.read_text())
    assert [(c["status"], c["reason"]) for c in st["candidates"]] == [
        ("applied", None),
        ("rejected", "ambiguous"),
        ("not_confirmed", "consistent"),
    ]


@pytest.mark.unit
def test_apply_keeps_note_mode(monkeypatch, capsys, tmp_path):
    path = confirmed_state(
        monkeypatch, capsys, tmp_path, [disc(S_REPORT, S_REPORT.replace("3", "4"))], ["contradicts"]
    )
    note = tmp_path / "note.md"
    note.write_text(NOTE)
    note.chmod(0o640)
    summary, _, note, _ = apply(monkeypatch, capsys, tmp_path, path, note_text=None)
    assert summary["applied"] == 1
    assert oct(os.stat(note).st_mode & 0o777) == oct(0o640)


@pytest.mark.unit
def test_apply_without_state_reports_no_state(monkeypatch, capsys, tmp_path):
    summary, warns, note, pre = apply(monkeypatch, capsys, tmp_path, tmp_path / "missing.json")
    assert summary["ran"] is False and summary["reason"] == "no_state"
    assert summary["applied"] == 0 and summary["cost"] == 0.0
    assert set(summary) == {"ran", "reason", "cost", *dr_pipeline.AUDIT_SUM_KEYS}
    assert warns == [] and note.read_text() == NOTE and not pre.exists()


@pytest.mark.unit
def test_apply_after_stage1_failure_leaves_note_untouched(monkeypatch, capsys, tmp_path):
    path, _, _ = stage1(monkeypatch, capsys, tmp_path, [], cls="E_TRANSIENT", raw="")
    summary, warns, note, pre = apply(monkeypatch, capsys, tmp_path, path)
    assert summary["ran"] is False and summary["reason"] == "E_TRANSIENT"
    assert warns == [] and note.read_text() == NOTE and not pre.exists()


@pytest.mark.unit
def test_apply_with_unreadable_note_is_ran_false(monkeypatch, capsys, tmp_path):
    path = confirmed_state(monkeypatch, capsys, tmp_path, [disc(S_REPORT, "x。")], ["contradicts"])
    summary, _, note, _ = apply(monkeypatch, capsys, tmp_path, path, note_text=None)
    assert summary["ran"] is False and summary["reason"] == "note_unreadable"
    assert not note.exists()
    assert json.loads(path.read_text())["reason"] == "note_unreadable"


@pytest.mark.unit
def test_apply_replaces_a_symlinked_pre_audit_dir(monkeypatch, capsys, tmp_path):
    path = confirmed_state(monkeypatch, capsys, tmp_path, [disc(S_REPORT, "x")], ["contradicts"])
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    (tmp_path / "pre-audit").symlink_to(elsewhere)
    _, _, _, pre = apply(monkeypatch, capsys, tmp_path, path)
    assert not (tmp_path / "pre-audit").is_symlink() and pre.read_text() == NOTE
    assert list(elsewhere.iterdir()) == []


@pytest.mark.unit
def test_apply_that_cannot_write_the_note_reverts_to_rejected(monkeypatch, capsys, tmp_path):
    notes = tmp_path / "notes"
    notes.mkdir()
    note = notes / "note.md"
    note.write_text(NOTE)
    path = confirmed_state(
        monkeypatch, capsys, tmp_path, [disc(S_REPORT, S_REPORT.replace("3", "4"))], ["contradicts"]
    )
    notes.chmod(0o500)
    try:
        rc, out, _ = run_cmd(
            monkeypatch,
            capsys,
            ["audit-apply", str(path), str(note), str(tmp_path / "pre" / "x.md")],
        )
    finally:
        notes.chmod(0o700)
    assert rc == 0
    summary, *warns = out.splitlines()
    summary = json.loads(summary)
    assert summary["applied"] == 0 and summary["rejected"] == 1 and summary["confirmed"] == 1
    assert note.read_text() == NOTE and any("ノートは元のまま" in w for w in warns)
    assert json.loads(path.read_text())["candidates"][0]["reason"] == "write_failed"


@pytest.mark.unit
def test_apply_applies_several_candidates_in_order(monkeypatch, capsys, tmp_path):
    a = S_REPORT.replace("3 か国", "4 か国")
    b = S_STUDY.replace("120 人", "210 人")
    path = confirmed_state(
        monkeypatch,
        capsys,
        tmp_path,
        [disc(S_REPORT, a), disc(S_STUDY, b)],
        ["contradicts", "contradicts"],
    )
    summary, warns, note, _ = apply(monkeypatch, capsys, tmp_path, path)
    assert summary["applied"] == 2 and warns == []
    assert note.read_text() == NOTE.replace(S_REPORT, a).replace(S_STUDY, b)


# === audit-prompt / note-kind / audit-config ===


@pytest.mark.unit
def test_audit_prompt_inlines_note_and_evidence(monkeypatch, capsys, tmp_path):
    note = tmp_path / "2026-11-07_x.md"
    note.write_text(NOTE)
    ev = tmp_path / "evidence.md"
    ev.write_text("- https://example.com/report §2\n")
    rc, out, _ = run_cmd(monkeypatch, capsys, ["audit-prompt", str(note), str(ev), "2026-11-07"])
    assert rc == 0
    assert NOTE in out and "https://example.com/report §2" in out
    assert "2026-11-07_x.md" in out and "ノートの公開日: 2026-11-07" in out


@pytest.mark.unit
def test_audit_prompt_without_evidence_and_with_long_evidence(monkeypatch, capsys, tmp_path):
    note = tmp_path / "n.md"
    note.write_text(NOTE)
    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["audit-prompt", str(note), str(tmp_path / "none"), "2026-11-07"]
    )
    assert rc == 0 and "根拠ファイルは無い" in out
    ev = tmp_path / "ev.md"
    ev.write_text("あ" * (dr_pipeline.AUDIT_EVIDENCE_MAX_CHARS + 10))
    rc, out, _ = run_cmd(monkeypatch, capsys, ["audit-prompt", str(note), str(ev), "2026-11-07"])
    assert rc == 0 and "以下 10 字を省略" in out


@pytest.mark.unit
@pytest.mark.parametrize("case", ["missing", "too-long", "bad-date"])
def test_audit_prompt_refuses(monkeypatch, capsys, tmp_path, case):
    note = tmp_path / "n.md"
    if case == "too-long":
        note.write_text("あ" * (dr_pipeline.AUDIT_NOTE_MAX_CHARS + 1))
    elif case == "bad-date":
        note.write_text(NOTE)
    date_s = "2026/11/07" if case == "bad-date" else "2026-11-07"
    rc, out, _ = run_cmd(monkeypatch, capsys, ["audit-prompt", str(note), "", date_s])
    assert rc == 1 and out == ""


@pytest.mark.unit
def test_note_kind(monkeypatch, capsys, tmp_path):
    note = tmp_path / "n.md"
    note.write_text(NOTE.replace("kind: article", "kind: brief"))
    assert run_cmd(monkeypatch, capsys, ["note-kind", str(note)])[:2] == (0, "brief\n")
    note.write_text("# 題だけ\n")
    assert run_cmd(monkeypatch, capsys, ["note-kind", str(note)])[:2] == (0, "article\n")
    assert run_cmd(monkeypatch, capsys, ["note-kind", str(tmp_path / "none")])[0] == 1


@pytest.mark.unit
@pytest.mark.parametrize(
    ("body", "out"),
    [
        ("", "false\topus\n"),
        ("[audit]\nenabled = true\n", "true\topus\n"),
        (
            '[audit]\nenabled = false\nmodel = "claude-opus-5-5[1m]"\n',
            "false\tclaude-opus-5-5[1m]\n",
        ),
    ],
)
def test_audit_config(monkeypatch, capsys, tmp_path, body, out):
    cfg = tmp_path / "c.toml"
    cfg.write_text(body)
    assert run_cmd(monkeypatch, capsys, ["audit-config", str(cfg)])[:2] == (0, out)


@pytest.mark.unit
@pytest.mark.parametrize(
    "body",
    [
        '[audit]\nenabled = "yes"\n',
        '[audit]\nmodel = "op us"\n',
        "[audit]\nmodel = 1\n",
        "[audit]\nturns = 3\n",
        'audit = "on"\n',
        "[audit\n",
    ],
)
def test_audit_config_rejects(monkeypatch, capsys, tmp_path, body):
    cfg = tmp_path / "c.toml"
    cfg.write_text(body)
    rc, out, err = run_cmd(monkeypatch, capsys, ["audit-config", str(cfg)])
    assert rc == 2 and out == "" and "audit-config:" in err


@pytest.mark.unit
def test_audit_config_missing_file_is_rc2(monkeypatch, capsys, tmp_path):
    assert run_cmd(monkeypatch, capsys, ["audit-config", str(tmp_path / "none")])[0] == 2


@pytest.mark.unit
@pytest.mark.parametrize(
    "cmd",
    [
        ["audit-config"],
        ["note-kind"],
        ["audit-prompt", "a", "b"],
        ["audit-stage1", "a", "b"],
        ["audit-confirm-prompt", "a"],
        ["audit-confirm-record", "a", "b"],
        ["audit-apply", "a", "b"],
    ],
)
def test_audit_commands_usage(monkeypatch, capsys, cmd):
    rc, _, err = run_cmd(monkeypatch, capsys, cmd)
    assert rc == 64 and "usage:" in err


# === billing-config: [audit] enabled のときだけ予約額に呼3 が入る ===


@pytest.mark.unit
def test_billing_reserve_includes_audit_only_when_enabled(monkeypatch, capsys, tmp_path):
    base = (
        '[billing]\nmode = "api"\nenv_file = "/x/env"\nmonthly_cap_usd = 100\n'
        "daily_cap_usd = 10\ncall1_max_usd = 4\ncall2_max_usd = 1.5\n"
        "audit_max_usd = 1.5\naudit_confirm_max_usd = 0.2\n"
    )
    cfg = tmp_path / "c.toml"
    cfg.write_text(base)
    rc, out, _ = run_cmd(monkeypatch, capsys, ["billing-config", str(cfg)])
    assert rc == 0 and out.rstrip("\n").split("\t")[6:] == ["1.5", "0.2", "5.5", "2.5"]
    cfg.write_text(base + "[audit]\nenabled = true\n")
    rc, out, _ = run_cmd(monkeypatch, capsys, ["billing-config", str(cfg)])
    assert rc == 0 and out.rstrip("\n").split("\t")[8:] == ["8", "2.5"]


@pytest.mark.unit
def test_billing_rejects_daily_cap_below_reserve_with_audit(monkeypatch, capsys, tmp_path):
    cfg = tmp_path / "c.toml"
    cfg.write_text(
        '[billing]\nmode = "api"\ndaily_cap_usd = 6\ncall1_max_usd = 4\ncall2_max_usd = 1.5\n'
        "[audit]\nenabled = true\n"
    )
    rc, _, err = run_cmd(monkeypatch, capsys, ["billing-config", str(cfg)])
    assert rc == 2 and "audit_max_usd" in err and "audit_confirm_max_usd" in err


@pytest.mark.unit
@pytest.mark.parametrize("key", ["audit_max_usd", "audit_confirm_max_usd"])
def test_billing_rejects_non_positive_audit_caps(monkeypatch, capsys, tmp_path, key):
    cfg = tmp_path / "c.toml"
    cfg.write_text(f'[billing]\nmode = "api"\n{key} = 0\n')
    rc, _, err = run_cmd(monkeypatch, capsys, ["billing-config", str(cfg)])
    assert rc == 2 and key in err


@pytest.mark.unit
def test_billing_config_reports_broken_audit_table(monkeypatch, capsys, tmp_path):
    cfg = tmp_path / "c.toml"
    cfg.write_text('[audit]\nenabled = "yes"\n')
    rc, _, err = run_cmd(monkeypatch, capsys, ["billing-config", str(cfg)])
    assert rc == 2 and "[audit].enabled" in err


# === metrics-append の AUDIT 行と expect-check の audit_* ===


VERIFY_LINE = (
    'VERIFY\t{"supported": 3, "partial": 1, "unsupported": 0, "unverifiable": 0, "edits": 2, '
    '"ran": true}\n'
)


def metrics_append(monkeypatch, capsys, tmp_path, stdin):
    path = tmp_path / "metrics.jsonl"
    rc, _, err = run_cmd(
        monkeypatch,
        capsys,
        ["metrics-append", str(path), "2026-11-08", "OK", "1", "0"],
        stdin=stdin,
    )
    assert rc == 0, err
    return json.loads(path.read_text().splitlines()[-1])


def audit_line(**kw):
    row = dr_pipeline._audit_summary(None)
    row.update(kw)
    return "AUDIT\t" + json.dumps(row) + "\n"


@pytest.mark.unit
def test_metrics_append_sums_audit_lines_and_adds_cost_to_total(monkeypatch, capsys, tmp_path):
    stdin = (
        'RUN\t{"total_cost_usd": 1.0, "num_turns": 5}\n'
        + VERIFY_LINE
        + VERIFY_LINE
        + audit_line(ran=True, claims=10, candidates=2, confirmed=1, applied=1, cost=0.3, turns=9)
        + audit_line(ran=False, reason="E_TRANSIENT", cost=0.1)
        + "AUDIT\tnot json\n"
    )
    rec = metrics_append(monkeypatch, capsys, tmp_path, stdin)
    v = rec["verification"]
    assert v["audit_lines"] == 2 and v["audit_ran"] == 1
    assert v["audit_claims"] == 10 and v["audit_candidates"] == 2
    assert v["audit_confirmed"] == 1 and v["audit_applied"] == 1 and v["audit_rejected"] == 0
    assert v["audit_turns"] == 9 and v["audit_cost"] == 0.4
    assert rec["total_cost"] == pytest.approx(1.4)


@pytest.mark.unit
def test_metrics_append_without_audit_keeps_the_old_shape(monkeypatch, capsys, tmp_path):
    v = metrics_append(monkeypatch, capsys, tmp_path, VERIFY_LINE)["verification"]
    assert not any(k.startswith("audit_") for k in v)


@pytest.mark.unit
def test_metrics_append_audit_without_verify_is_not_recorded(monkeypatch, capsys, tmp_path):
    rec = metrics_append(monkeypatch, capsys, tmp_path, audit_line(ran=True, applied=1))
    assert rec["verification"] is None


def expect(monkeypatch, capsys, tmp_path, records, expr):
    path = tmp_path / "m.jsonl"
    path.write_text("".join(json.dumps(r) + "\n" for r in records))
    rc, out, _ = run_cmd(
        monkeypatch, capsys, ["expect-check", str(path)], stdin=f"2026-11-01\t{expr}\n"
    )
    assert rc == 0
    return out.strip()


AUDIT_RECS = [
    {
        "date": "2026-11-02",
        "verification": {"audit_lines": 1, "audit_ran": 1, "audit_applied": 2, "audit_cost": 0.4},
    },
    {
        "date": "2026-11-03",
        "verification": {"audit_lines": 1, "audit_ran": 0, "audit_applied": 0, "audit_cost": 0.0},
    },
    {"date": "2026-11-04", "verification": {"supported": 1}},  # 監査の無い日は分母に入れない
    {"date": "2026-11-05", "verification": None},
]


@pytest.mark.unit
@pytest.mark.parametrize(
    ("expr", "head", "shown"),
    [
        ("audit_applied_mean >= 1", "ACHIEVED", "実測 1.0"),
        ("audit_ran_rate >= 0.9", "NOT_ACHIEVED", "実測 0.5"),
        ("audit_cost_mean <= 0.5", "ACHIEVED", "実測 0.2"),
        ("audit_rejected_mean <= 0", "ACHIEVED", "実測 0.0"),
    ],
)
def test_expect_check_audit_means_are_per_audited_line(
    monkeypatch, capsys, tmp_path, expr, head, shown
):
    out = expect(monkeypatch, capsys, tmp_path, AUDIT_RECS, expr)
    assert out.startswith(head + "\t") and shown in out, out


@pytest.mark.unit
@pytest.mark.parametrize("expr", ["audit_applied_mean >= 1", "audit_bogus_mean >= 1"])
def test_expect_check_audit_without_audited_lines_is_insufficient(
    monkeypatch, capsys, tmp_path, expr
):
    recs = AUDIT_RECS[2:] if "applied" in expr else AUDIT_RECS
    out = expect(monkeypatch, capsys, tmp_path, recs, expr)
    assert out.startswith("INSUFFICIENT_DATA"), out
