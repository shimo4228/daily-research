#!/usr/bin/env python3
"""eval_run — sandbox-run.sh の出力 dir 1 つから決定論の指標を JSON で出す (stdlib のみ、dev 専用)。

    python3 scripts/dev/eval_run.py <out_dir> [--check-links] [--write]

--write は <out_dir>/eval.json にも書く。--check-links は出典 URL を HTTP で叩いて状態を足す (遅い)。
LLM judge は使わない (rule evals.md / ADR-0010)。指標の定義はこの file が正本で、試すコードの
dr_pipeline ではなく、この道具と同じ checkout の scripts/lib/dr_pipeline.py の lint を使う
(A/B の両腕を同じ物差しで測るため)。

出力の主な節: run (有効性・課金経路・所要) / state (receipt の状態) / receipt (妥当性) /
note・draft (呼2 後の最終版と呼1 の原稿: lint・本文字数・出典・日付の付与率・禁止表現) /
draft_vs_final (呼2 の改稿量) / call1・call2 (費用相当・turns・token・検索) / verify / evidence /
novelty (同じ line の過去の問いとの最大類似度)。
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
DR_PY = os.path.join(HERE, "..", "lib", "dr_pipeline.py")
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import dr_pipeline  # noqa: E402 — 同じ checkout の parser-of-record (searches・receipt の契約)

# 本文の段落が日付を持つか (ISO / スラッシュ / 年月日 / 月日 / 英語の月名)。as-of の付与は
# 両プロトコルの大原則「すべての claim に as-of 日付を付ける」(repo 大原則 4 / ecosystem 大原則 3)。
# 年は 19xx / 20xx、月は 1-12、日は 1-31 に限る (「1500-3000」のような数の範囲を日付と数えない)
_MONTHS = (
    r"(?<![A-Za-z])(?:January|February|March|April|May|June|July|August|September|October"
    r"|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec)\.?"
)
_YEAR = r"(?<!\d)(?:19|20)\d{2}"
_MON = r"(?:1[0-2]|0?[1-9])"
_DAY = r"(?:3[01]|[12]\d|0?[1-9])"
# MM-DD の直後に倍率・単位・百分率が来るのは数の範囲 (「10-20 倍」「10-12 件」)
_NOT_A_RANGE = (
    r"(?![\d.%\-])(?!\s*(?:倍|%|％|件|回|人|本|個|社|円|ドル|字|行|語|分|秒|時間|日間|週|か月|ヶ月"
    r"|年|歳|点|ページ|×|x(?![A-Za-z])))"
)
DATE_RE = re.compile(
    rf"{_YEAR}\s*-\s*{_MON}(?:\s*-\s*{_DAY})?(?!\d)"
    rf"|{_YEAR}\s*/\s*{_MON}(?:\s*/\s*{_DAY})?(?!\d)"
    rf"|{_YEAR}\s*年\s*{_MON}\s*月"
    rf"|(?<!\d){_MON}\s*月\s*{_DAY}\s*日"
    # 年を略した MM-DD (ノートは同年の日付を "09-03" と書く)。範囲・小数・百分率は除く
    rf"|(?<![\d.\-])(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01]){_NOT_A_RANGE}"
    rf"|{_MONTHS}\s+\d{{1,2}},?\s+(?:19|20)\d{{2}}(?!\d)"
    rf"|(?<!\d)\d{{1,2}}\s+{_MONTHS}\s+(?:19|20)\d{{2}}(?!\d)"
    rf"|{_MONTHS}\s+(?:19|20)\d{{2}}(?!\d)"
)
MIN_PARAGRAPH_CHARS = 30  # これより短い段落 (見出しの続き・1 語の行) は付与率の分母に入れない

# 禁止表現。出所はプロトコル (prompts/*-research-protocol.md) とテンプレートの文体規律:
# - should / request: 「承認要求・『〜すべき』・手順の列挙は書かない」(Step 5 含意 / テンプレート規律 1)
# - no_precedent: 「『先行例なし』『誰もやっていない』と断定しない」(Step 4 の 7 / 8)
# - ghost_ref: 「座標だけの参照（『指針(b)』『N 日前のレポート』『watchlist の 3 番』）は書かない」(文体規律 3)
FORBIDDEN = {
    # 連体の慣用 (驚くべき・恐るべき・然るべき・来るべき 等) は勧告ではないので数えない
    "should": re.compile(
        r"(?<!驚く)(?<!恐る)(?<!然る)(?<!しかる)(?<!来る)(?<!記念す)(?<!特筆す)(?<!愛す)(?<!憎む)べき"
    ),
    "request": re.compile(r"してください|して下さい|ご検討|ご承認|承認を(?:お願い|求め)"),
    "no_precedent": re.compile(
        r"先行例(?:は|が)?(?:なし|ない|無い)|誰もやっていない|前例(?:は|が)?(?:なし|ない|無い)"
    ),
    "ghost_ref": re.compile(
        r"\d+\s*日前の(?:レポート|ノート|記事)|指針\s*[（(][A-Za-z0-9][)）]|watchlist\s*の\s*\d+\s*番"
    ),
}
# 括弧の認識論注記 (「1 本あたり 2 箇所まで」— 大原則 5 / 文体規律 4)
EPISTEMIC_RE = re.compile(
    r"[（(][^（）()\n]{0,30}?(?:断定しない|断定できない|解釈|推論|推測|未確認|検算)[^（）()\n]{0,30}?[)）]"
)
EPISTEMIC_LIMIT = 2
# 第一文は外部の出来事から (文体規律 1)。repo・台帳・過去レポート・過去 run から書き始めない
FIRST_SENTENCE_INTERNAL_RE = re.compile(
    r"この repo|本 repo|台帳|過去の?レポート|前回の?(?:レポート|ノート|run|報告)|ADR|pending\.md|brief\.md|watchlist"
)
URL_RE = re.compile(r"\[[^\]]*\]\((https?://[^)\s]+)\)")
TAIL_HEADINGS = ("## 機会メモ", "## ソース")


# --- note の解析 ----------------------------------------------------------------------


def split_note(text):
    """(frontmatter dict, body, sources_section) を返す。body は frontmatter と H1 の後から、
    末尾固定節 (機会メモ / ソース) の最初の見出しの前まで。"""
    fm, rest = {}, text
    m = re.match(r"---\n(.*?)\n---\n?", text, re.DOTALL)
    if m:
        rest = text[m.end() :]
        for raw in m.group(1).splitlines():
            key, sep, value = raw.partition(":")
            if sep and re.fullmatch(r"[A-Za-z_]+", key.strip()):
                fm[key.strip()] = value.split("  #", 1)[0].strip().strip("\"'")
    rest = re.sub(r"\A\s*# [^\n]*\n", "", rest)
    cut = [rest.find(h) for h in TAIL_HEADINGS if rest.find(h) >= 0]
    body = rest[: min(cut)] if cut else rest
    src_at = rest.find("## ソース")
    sources = rest[src_at:] if src_at >= 0 else ""
    return fm, body, sources


def paragraphs(body):
    """空行で区切った塊のうち、見出しと短い塊を除いたもの。"""
    out = []
    for block in re.split(r"\n\s*\n", body):
        block = block.strip()
        if not block or block.startswith("#"):
            continue
        if len(re.sub(r"\s", "", block)) >= MIN_PARAGRAPH_CHARS:
            out.append(block)
    return out


def first_sentence(body):
    for p in paragraphs(body):
        return re.split(r"(?<=[。．.!?！？])\s*", p, maxsplit=1)[0][:300]
    return ""


def body_chars(body):
    """本文の字数 = 空白とリンク先 URL を除いた文字数 (プロトコルの「本文 3,000 字以内」の目安)。"""
    return len(re.sub(r"\s", "", re.sub(r"\]\([^)]*\)", "]", body)))


def _lint(note_path, date, config):
    """dr_pipeline report-lint を、この note だけを置いた一時 dir に当てる。"""
    with tempfile.TemporaryDirectory() as d:
        with open(note_path, encoding="utf-8") as f:
            text = f.read()
        with open(os.path.join(d, f"{date}_lint_target.md"), "w", encoding="utf-8") as f:
            f.write(text)
        proc = subprocess.run(
            [sys.executable, DR_PY, "report-lint", d, date, config or os.path.join(d, "none.toml")],
            capture_output=True,
            text=True,
            check=False,
        )
    try:
        r = json.loads(proc.stdout)["results"][0]
    except (json.JSONDecodeError, KeyError, IndexError):
        return {"error": proc.stderr.strip()[:300] or "report-lint produced no result"}
    return {"hard": r.get("hard", []), "soft": r.get("soft", [])}


def analyze_note(path, date, config=None):
    """note 1 本の決定論の指標。"""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    fm, body, sources = split_note(text)
    paras = paragraphs(body)
    dated = sum(1 for p in paras if DATE_RE.search(p))
    forbidden = {k: len(rx.findall(body)) for k, rx in FORBIDDEN.items()}
    epistemic = len(EPISTEMIC_RE.findall(body))
    first = first_sentence(body)
    urls = list(dict.fromkeys(URL_RE.findall(text)))
    lint = _lint(path, date, config)
    return {
        "name": os.path.basename(path),
        "kind": fm.get("kind", "article"),
        "frontmatter": {k: fm.get(k) for k in ("kind", "sources", "actionable", "question")},
        "total_chars": len(text),
        "body_chars": body_chars(body),
        "paragraphs": len(paras),
        "dated_paragraphs": dated,
        "date_coverage": round(dated / len(paras), 3) if paras else None,
        "unique_urls": len(urls),
        "sources_section": len(set(URL_RE.findall(sources))),
        "urls": urls,
        "forbidden": forbidden,
        "forbidden_total": sum(forbidden.values()),
        "epistemic_parentheticals": epistemic,
        "epistemic_over_limit": max(0, epistemic - EPISTEMIC_LIMIT),
        "first_sentence": first,
        "first_sentence_internal": bool(FIRST_SENTENCE_INTERNAL_RE.search(first)),
        "lint": lint,
        "lint_hard": len(lint.get("hard", [])) if "error" not in lint else None,
        "lint_soft": len(lint.get("soft", [])) if "error" not in lint else None,
    }


# --- 呼び出し・検証・receipt ----------------------------------------------------------


def call_metrics(d):
    """claude -p の result JSON 1 つの費用相当・turns・token・検索。サブスクでも total_cost_usd は
    API 単価での換算値として出る (請求額ではない)。"""
    if not isinstance(d, dict) or not d:
        return None
    u = d.get("usage") or {}
    denials = d.get("permission_denials") or []
    return {
        "cost_usd": round(float(d.get("total_cost_usd") or 0), 4),
        "turns": int(d.get("num_turns") or 0),
        "duration_s": round((d.get("duration_ms") or 0) / 1000),
        "input_tokens": int(u.get("input_tokens") or 0),
        "output_tokens": int(u.get("output_tokens") or 0),
        "cache_creation_input_tokens": int(u.get("cache_creation_input_tokens") or 0),
        "cache_read_input_tokens": int(u.get("cache_read_input_tokens") or 0),
        "searches": dr_pipeline._searches(d),
        "permission_denials": len(denials),
        "denied_tools": sorted({str(x.get("tool_name")) for x in denials if isinstance(x, dict)}),
        "is_error": bool(d.get("is_error")),
        "subtype": d.get("subtype"),
        "models": sorted((d.get("modelUsage") or {}).keys()),
    }


_SUMMED_CALL_KEYS = (
    "cost_usd",
    "turns",
    "duration_s",
    "input_tokens",
    "output_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
    "searches",
    "permission_denials",
)


def calls_metrics(results):
    """同じ呼び出しの全 attempt (retry を含む) の合算。費用・turns・token・検索・denial は足し、
    is_error / subtype は最後の attempt のもの。retry の日に 1 回目の費用を落とさない。"""
    per = [m for m in (call_metrics(d) for d in results) if m]
    if not per:
        return None
    total = dict(per[-1])
    for k in _SUMMED_CALL_KEYS:
        total[k] = sum(m[k] for m in per)
    total["cost_usd"] = round(total["cost_usd"], 4)
    total["denied_tools"] = sorted({t for m in per for t in m["denied_tools"]})
    total["models"] = sorted({x for m in per for x in m["models"]})
    total["attempts"] = len(per)
    return total


def call_results(out_dir, name):
    """sandbox_lib collect が書いた <name>.attempt<i>.json (i 昇順) と <name>.json (最後の attempt)。"""
    found = []
    i = 1
    while (d := _load_json(os.path.join(out_dir, f"{name}.attempt{i}.json"))) is not None:
        found.append(d)
        i += 1
    last = _load_json(os.path.join(out_dir, f"{name}.json"))
    if last is not None:
        found.append(last)
    return found


def verify_metrics(d):
    if not isinstance(d, dict):
        return {"ran": False}
    counts = {k: dr_pipeline._nonneg_int(d.get(k)) for k in dr_pipeline.VERIFY_KEYS}
    total = sum(counts[k] for k in ("supported", "partial", "unsupported", "unverifiable"))
    return {
        "ran": True,
        **counts,
        "total": total,
        "supported_rate": round(counts["supported"] / total, 3) if total else None,
    }


def receipt_metrics(path, date, line, note_name):
    if not os.path.isfile(path):
        return {"present": False, "valid": False}
    proc = subprocess.run(
        [sys.executable, DR_PY, "receipt-read", path, date, line],
        capture_output=True,
        text=True,
        check=False,
    )
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, json.JSONDecodeError):
        d = {}
    keys = list(d) if isinstance(d, dict) else []
    report = d.get("report") if isinstance(d, dict) else None
    return {
        "present": True,
        "valid": proc.returncode == 0,
        "error": proc.stderr.strip()[:300] or None,
        "missing_keys": [k for k in dr_pipeline.RECEIPT_KEYS if k not in keys],
        "extra_keys": [k for k in keys if k not in dr_pipeline.RECEIPT_KEYS],
        "key_order_matches": [k for k in keys if k in dr_pipeline.RECEIPT_KEYS]
        == [k for k in dr_pipeline.RECEIPT_KEYS if k in keys],
        "report_matches_note": (report or None) == note_name,
        "status": d.get("status") if isinstance(d, dict) else None,
        "reason_code": d.get("reason_code") if isinstance(d, dict) else None,
        "question": d.get("question") if isinstance(d, dict) else None,
    }


def evidence_metrics(path):
    """根拠ファイルの表の claim 行 (| C1 | …) の件数と fetch_status の内訳。"""
    if not os.path.isfile(path):
        return {"present": False, "claims": 0}
    with open(path, encoding="utf-8") as f:
        rows = [r for r in f.read().splitlines() if re.match(r"\|\s*C\d+\s*\|", r)]
    status = {"本文確認済": 0, "部分取得": 0, "取得失敗": 0, "other": 0}
    for r in rows:
        cell = r.strip().strip("|").split("|")[-1].strip()
        key = next((k for k in status if k != "other" and cell.startswith(k)), "other")
        status[key] += 1
    return {"present": True, "claims": len(rows), "fetch_status": status}


# --- 重複 (過去の問いとの類似度) ------------------------------------------------------


def _norm(s):
    s = unicodedata.normalize("NFKC", str(s or "")).lower()
    return "".join(ch for ch in s if ch.isalnum())


def ngrams(s, n=2):
    s = _norm(s)
    return {s[i : i + n] for i in range(len(s) - n + 1)} if len(s) >= n else ({s} if s else set())


def jaccard(a, b, n=2):
    x, y = ngrams(a, n), ngrams(b, n)
    return round(len(x & y) / len(x | y), 3) if x and y else 0.0


def novelty(question, history, n=2, top=3):
    """問いと、同じ line の過去の問い (無ければ題) との文字 n-gram Jaccard の最大値と上位。"""
    if not question:
        return {"question": None, "n_past": len(history), "max_jaccard": None, "top": []}
    scored = []
    for t in history:
        past = t.get("question") or t.get("title")
        if past:
            scored.append((jaccard(question, past, n), t.get("date"), str(past)[:160]))
    scored.sort(key=lambda s: s[0], reverse=True)
    return {
        "question": question,
        "ngram": n,
        "n_past": len(scored),
        "max_jaccard": scored[0][0] if scored else 0.0,
        "top": [{"score": s, "date": d, "past": p} for s, d, p in scored[:top]],
    }


def draft_vs_final(draft_path, final_path):
    """呼2 の改稿量: 行単位の差分 (追加・削除行) と文字の類似度。"""
    import difflib

    if not (os.path.isfile(draft_path) and os.path.isfile(final_path)):
        return None
    with open(draft_path, encoding="utf-8") as f:
        a = f.read()
    with open(final_path, encoding="utf-8") as f:
        b = f.read()
    diff = list(difflib.unified_diff(a.splitlines(), b.splitlines(), lineterm="", n=0))
    added = sum(1 for d in diff if d.startswith("+") and not d.startswith("+++"))
    removed = sum(1 for d in diff if d.startswith("-") and not d.startswith("---"))
    ratio = difflib.SequenceMatcher(None, a, b, autojunk=False).ratio()
    return {
        "lines_added": added,
        "lines_removed": removed,
        "edit_ratio": round(1 - ratio, 4),
        "chars_delta": len(b) - len(a),
    }


# --- 出典 URL の HTTP 状態 (--check-links) ---------------------------------------------


def _http_status(url, timeout=15):
    import urllib.error
    import urllib.request

    if not url.startswith(("http://", "https://")):
        return "skipped: scheme"
    headers = {"User-Agent": "Mozilla/5.0 (daily-research eval_run link check)"}
    for method in ("HEAD", "GET"):
        req = urllib.request.Request(url, method=method, headers=headers)  # noqa: S310 — scheme は上で http(s) に限定
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 — 同上
                return resp.status
        except urllib.error.HTTPError as e:
            if method == "HEAD" and e.code in (403, 405, 501):
                continue
            return e.code
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            return f"error: {type(e).__name__}"
    return "error: unreachable"


def check_links(urls):
    from concurrent.futures import ThreadPoolExecutor

    with ThreadPoolExecutor(max_workers=8) as ex:
        return dict(zip(urls, ex.map(_http_status, urls), strict=True))


# --- 全体 -----------------------------------------------------------------------------


def _load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def evaluate(out_dir, links=False):
    """出力 dir 1 つの指標 dict。"""

    def p(name):
        return os.path.join(out_dir, name)

    meta = _load_json(p("meta.json")) or {}
    date, line = meta.get("date", ""), meta.get("line", "")
    config = os.path.join(out_dir, "sandbox", "project", "config.toml")
    config = config if os.path.isfile(config) else None
    note_name = meta.get("note_name")
    receipt = receipt_metrics(p("receipt.json"), date, line, note_name)
    # 原稿の写しは呼2 の開始前に取れたときだけ呼1 の出力として使う (meta.draft は collect の判定)
    draft_ok = meta.get("draft") == "clean" and os.path.isfile(p("draft.md"))
    result = {
        "dir": os.path.abspath(out_dir),
        "line": line,
        "date": date,
        "mode": meta.get("mode"),
        "source": {k: meta.get(f"source_{k}") for k in ("kind", "ref", "sha", "dirty")},
        "run": {
            "valid": meta.get("valid"),
            "billing_ok": meta.get("billing_ok"),
            "billing_log": meta.get("billing_log"),
            "api_key_source": meta.get("api_key_source"),
            "isolation_ok": meta.get("isolation_ok"),
            "dr_exit": meta.get("dr_exit"),
            "duration_s": meta.get("duration_s"),
            "call1_attempts": meta.get("call1_attempts"),
            "notes_written": len(meta.get("notes_written") or []),
            "draft": meta.get("draft"),
        },
        "state": {
            "receipt_status": receipt.get("status"),
            "reason_code": receipt.get("reason_code"),
            "line_states": (_load_json(p("metrics.json")) or {}).get("line_states"),
        },
        "receipt": {k: v for k, v in receipt.items() if k not in ("status", "reason_code")},
        "note": analyze_note(p(note_name), date, config)
        if note_name and os.path.isfile(p(note_name))
        else None,
        "draft": analyze_note(p("draft.md"), date, config) if draft_ok else None,
        "draft_vs_final": draft_vs_final(p("draft.md"), p(note_name))
        if draft_ok and note_name
        else None,
        "call1": calls_metrics(call_results(out_dir, "call1")),
        "call2": calls_metrics(call_results(out_dir, "call2")),
        "verify": verify_metrics(_load_json(p("verify.json"))),
        "evidence": evidence_metrics(p("evidence.md")),
        "novelty": novelty(receipt.get("question"), _load_json(p("past_topics.line.json")) or []),
    }
    if links and result["note"]:
        result["note"]["link_status"] = check_links(result["note"]["urls"])
        bad = [
            u
            for u, s in result["note"]["link_status"].items()
            if not (isinstance(s, int) and s < 400)
        ]
        result["note"]["links_bad"] = len(bad)
    return result


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 1:
        print("usage: eval_run.py <out_dir> [--check-links] [--write]", file=sys.stderr)
        return 64
    result = evaluate(args[0], links="--check-links" in argv)
    text = json.dumps(result, ensure_ascii=False, indent=1)
    if "--write" in argv:
        with open(os.path.join(args[0], "eval.json"), "w", encoding="utf-8") as f:
            f.write(text + "\n")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
