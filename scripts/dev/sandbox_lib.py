#!/usr/bin/env python3
"""sandbox_lib — scripts/dev/sandbox-run.sh の Python 側 (stdlib のみ、dev 専用)。

sandbox-run.sh は本番の scripts/daily-research.sh を、run ごとに作る PROJECT_DIR と隔離 vault の中で
1 line だけ回す。この module はその前後の、shell で書くと壊れやすい部分を持つ:

- rewrite-config: MAIN の config.toml を写し、[billing] mode と [general] vault_path だけを書き換える。
  書き換え後を tomllib で読み直し、その 2 値以外が元と一致することを検査する (一致しなければ書かない)
- line-history: past_topics.json から 1 line 分 (aliases を含む) の履歴を抜き出す (eval の重複判定用)
- api-key-source: claude -p --output-format stream-json の init event から apiKeySource を出す
  ("none" = OAuth = サブスク。key の経路なら "ANTHROPIC_API_KEY" 等)
- collect: run 後の成果物を出力 dir に集め、meta.json を書き、課金経路と隔離を検査する

本番の scripts/lib/ は import しない — 試す側のコード (git ref / 作業ツリー) が変わっても、道具の
挙動は変わらないようにする。
"""

import json
import os
import re
import shutil
import sys
import tomllib

BILLING_SUBSCRIPTION = "subscription"

# collect の終了コード (sandbox-run.sh が自分の終了コードに写す)
RC_OK = 0
RC_BILLING_INVALID = 2
RC_ISOLATION = 4

_SECTION_RE = re.compile(r"^\s*\[\s*([^\[\]]+?)\s*\]\s*(#.*)?$")
_ARRAY_TABLE_RE = re.compile(r"^\s*\[\[")
_LOG_TS_RE = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] ")


# --- rewrite-config -------------------------------------------------------------------


def _toml_str(value):
    """TOML の basic string。JSON の escape は TOML basic string の部分集合として有効。"""
    return json.dumps(value, ensure_ascii=False)


def _set_key(lines, section, key, value_literal):
    """lines (改行なしの行のリスト) の [section] の key 行を置き換える。key 行が無ければ
    header の直後に足し、section が無ければ末尾に section ごと足す。新しいリストを返す。
    invariant: 置き換えるのは単一行の `key = ...` だけ。複数行の値は呼ぶ側の再検査が落とす。"""
    out = list(lines)
    key_re = re.compile(rf"^\s*{re.escape(key)}\s*=")
    start = None
    for i, line in enumerate(out):
        m = _SECTION_RE.match(line)
        if m and not _ARRAY_TABLE_RE.match(line) and m.group(1) == section:
            start = i
            break
    new_line = f"{key} = {value_literal}"
    if start is None:
        return [*out, "", f"[{section}]", new_line]
    end = len(out)
    for j in range(start + 1, len(out)):
        if _SECTION_RE.match(out[j]) or _ARRAY_TABLE_RE.match(out[j]):
            end = j
            break
    for j in range(start + 1, end):
        if key_re.match(out[j]):
            out[j] = new_line
            return out
    out.insert(start + 1, new_line)
    return out


def rewrite_config_text(text, vault_path):
    """config.toml の本文を、billing.mode = subscription / general.vault_path = vault_path に
    書き換えた本文を返す。他の値は保つ。検査に落ちたら ValueError。"""
    original = tomllib.loads(text)
    lines = text.splitlines()
    lines = _set_key(lines, "billing", "mode", _toml_str(BILLING_SUBSCRIPTION))
    lines = _set_key(lines, "general", "vault_path", _toml_str(vault_path))
    new_text = "\n".join(lines) + "\n"
    rewritten = tomllib.loads(new_text)
    expected = json.loads(json.dumps(original))
    expected.setdefault("billing", {})["mode"] = BILLING_SUBSCRIPTION
    expected.setdefault("general", {})["vault_path"] = vault_path
    if json.loads(json.dumps(rewritten)) != expected:
        raise ValueError(
            "rewritten config differs from the original beyond billing.mode / vault_path"
        )
    return new_text


def cmd_rewrite_config(argv):
    if len(argv) != 3:
        print("usage: rewrite-config <src_config> <dst_config> <vault_path>", file=sys.stderr)
        return 64
    src, dst, vault = argv
    with open(src, encoding="utf-8") as f:
        text = f.read()
    try:
        new_text = rewrite_config_text(text, vault)
    except (ValueError, tomllib.TOMLDecodeError) as e:
        print(f"rewrite-config: {e}", file=sys.stderr)
        return 1
    with open(dst, "w", encoding="utf-8") as f:
        f.write(new_text)
    os.chmod(dst, 0o600)
    return 0


# --- line-history ---------------------------------------------------------------------


def line_history(topics, tracks, line):
    """past_topics の topics から line (と aliases) の entry を日付順に返す。"""
    names = {line, *((tracks.get(line) or {}).get("aliases") or [])}
    items = [t for t in topics if isinstance(t, dict) and t.get("track") in names]
    return sorted(items, key=lambda t: str(t.get("date", "")))


def cmd_line_history(argv):
    if len(argv) != 4:
        print("usage: line-history <past_topics> <config> <line> <out_json>", file=sys.stderr)
        return 64
    past, config, line, out = argv
    try:
        with open(past, encoding="utf-8") as f:
            topics = json.load(f).get("topics", [])
    except (OSError, json.JSONDecodeError, AttributeError):
        topics = []
    with open(config, "rb") as f:
        tracks = tomllib.load(f).get("tracks", {})
    with open(out, "w", encoding="utf-8") as f:
        json.dump(line_history(topics, tracks, line), f, ensure_ascii=False, indent=1)
    return 0


# --- api-key-source -------------------------------------------------------------------

# claude の stream-json init event で認証の経路を表すキー ("none" = OAuth)
INIT_AUTH_FIELD = "apiKeySource"


def api_key_source(stream_text):
    """stream-json 出力の init event の INIT_AUTH_FIELD の値。見つからなければ ""。"""
    for raw in stream_text.splitlines():
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        try:
            d = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if d.get("type") == "system" and d.get("subtype") == "init":
            return str(d.get(INIT_AUTH_FIELD, ""))
    return ""


def cmd_api_key_source(argv):
    print(api_key_source(sys.stdin.read()))
    return 0


# --- collect --------------------------------------------------------------------------


def parse_log(text):
    """当日ログから呼1 / 呼2 の result JSON と課金経路の行を取り出す。
    daily-research.sh は result JSON を 1 行で log へ echo し、その前に "=== Line:" /
    "=== Clarity pass: <note> ===" の行を書く。直前の marker で呼1 / 呼2 を振り分ける。"""
    out = {"billing": [], "call1": [], "call2": [], "clarity_ts": None, "clarity_note": None}
    section = None
    for line in text.splitlines():
        if "] Billing: " in line:
            out["billing"].append(line.split("] Billing: ", 1)[1].split(" ", 1)[0])
        if "] === Line: " in line:
            section = "call1"
        elif "] === Clarity pass: " in line:
            section = "call2"
            m = _LOG_TS_RE.match(line)
            out["clarity_ts"] = m.group(1) if m else None
            out["clarity_note"] = line.split("] === Clarity pass: ", 1)[1].rstrip(" =")
        stripped = line.strip()
        if section and stripped[:1] in ("{", "["):
            try:
                d = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            if isinstance(d, list):
                d = next((e for e in d if isinstance(e, dict) and e.get("type") == "result"), {})
            if isinstance(d, dict) and d.get("type") == "result":
                out[section].append(d)
    return out


def newer_files(root, marker_mtime, skip_dirs=(".git",)):
    """root 以下で mtime が marker より新しい file / dir の path を返す (無ければ [])。"""
    found = []
    if not os.path.exists(root):
        return found
    if os.path.isfile(root):
        return [root] if os.stat(root).st_mtime > marker_mtime else []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in skip_dirs]
        for name in filenames:
            p = os.path.join(dirpath, name)
            try:
                if os.lstat(p).st_mtime > marker_mtime:
                    found.append(p)
            except OSError:
                continue
    return found


def _copy(src, dst):
    if src and os.path.isfile(src):
        shutil.copy2(src, dst)
        return True
    return False


def _write_json(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
        f.write("\n")


def _read_meta_tsv(path):
    """sandbox-run.sh が書いた "key<TAB>value" 行を dict にする。key の接尾辞 :int / :json で型を付ける。"""
    meta = {}
    if not path or not os.path.exists(path):
        return meta
    with open(path, encoding="utf-8") as f:
        for raw in f.read().splitlines():
            key, sep, value = raw.partition("\t")
            if not sep:
                continue
            if key.endswith(":int"):
                key, value = key[:-4], int(value) if re.fullmatch(r"-?\d+", value) else None
            elif key.endswith(":json"):
                key, value = key[:-5], json.loads(value) if value else None
            meta[key] = value
    return meta


def _collect_artifacts(a, meta):
    """成果物を out に写し、meta に名前と件数を書く。"""
    runs = os.path.join(a["proj"], "state", a["line"], "runs")
    date, line, out = a["date"], a["line"], a["out"]
    notes = []
    if os.path.isdir(a["report_dir"]):
        notes = sorted(
            (
                n
                for n in os.listdir(a["report_dir"])
                if n.startswith(f"{date}_{line}_") and n.endswith(".md")
            ),
            key=lambda n: os.stat(os.path.join(a["report_dir"], n)).st_mtime,
        )
    meta["notes_written"] = notes
    meta["note_name"] = notes[-1] if notes else None
    if notes:
        _copy(os.path.join(a["report_dir"], notes[-1]), os.path.join(out, notes[-1]))
    meta["receipt"] = _copy(os.path.join(runs, f"{date}.json"), os.path.join(out, "receipt.json"))
    meta["evidence"] = _copy(os.path.join(runs, f"{date}.md"), os.path.join(out, "evidence.md"))
    meta["verify"] = _copy(
        os.path.join(runs, f"{date}.verify.json"), os.path.join(out, "verify.json")
    )
    state = os.path.join(a["proj"], "state", line)
    _copy(os.path.join(state, "pending.md"), os.path.join(out, "pending.after.md"))
    _copy(os.path.join(state, "watched-sources.md"), os.path.join(out, "watched-sources.after.md"))
    _copy(os.path.join(a["proj"], "logs", f"{date}.log"), os.path.join(out, "run.log"))
    metrics = os.path.join(a["proj"], "metrics.jsonl")
    meta["metrics"] = False
    if os.path.isfile(metrics):
        with open(metrics, encoding="utf-8") as f:
            rows = [r for r in f.read().splitlines() if r.strip()]
        if rows:
            _write_json(os.path.join(out, "metrics.json"), json.loads(rows[-1]))
            meta["metrics"] = True


def _collect_calls(a, meta):
    """ログから呼1 / 呼2 の result JSON を写し、課金経路と draft の鮮度を meta に書く。"""
    from datetime import datetime

    log_path = os.path.join(a["out"], "run.log")
    text = ""
    if os.path.isfile(log_path):
        with open(log_path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    parsed = parse_log(text)
    for i, d in enumerate(parsed["call1"], 1):
        name = "call1.json" if i == len(parsed["call1"]) else f"call1.attempt{i}.json"
        _write_json(os.path.join(a["out"], name), d)
    if parsed["call2"]:
        _write_json(os.path.join(a["out"], "call2.json"), parsed["call2"][-1])
    meta["call1_attempts"] = len(parsed["call1"])
    meta["call2_ran"] = bool(parsed["call2"])
    meta["billing_log"] = parsed["billing"]
    draft = os.path.join(a["out"], "draft.md")
    meta["draft"] = None
    if os.path.isfile(draft) and parsed["clarity_ts"]:
        marker = datetime.strptime(parsed["clarity_ts"], "%Y-%m-%d %H:%M:%S").timestamp()
        # 写しの mtime (cp -p で保つ) が「呼2 開始」の log 行の秒より後なら、呼2 の編集が混ざった版
        meta["draft"] = "clean" if os.stat(draft).st_mtime < marker + 1 else "after-clarity-start"
    elif parsed["clarity_note"]:
        meta["draft"] = "missing"
    return parsed


def _check_isolation(a, meta):
    """隔離の外 (本物の vault のレポート dir・MAIN の私的ファイル・接地 repo) の新しい file を数える。"""
    marker = os.stat(a["marker"]).st_mtime
    roots = [a["real_report_dir"]]
    main = a.get("main")
    if main:
        roots += [
            os.path.join(main, "state"),
            os.path.join(main, "logs"),
            os.path.join(main, "past_topics.json"),
            os.path.join(main, "metrics.jsonl"),
            os.path.join(main, "config.toml"),
        ]
    if a.get("target"):
        roots.append(a["target"])
    violations = []
    for r in roots:
        if r:
            violations += newer_files(r, marker)
    meta["isolation"] = {"checked": [r for r in roots if r], "violations": violations}
    return not violations


def collect(a):
    """run 後の集約。戻り値は (rc, meta)。rc: 0 = 有効 / 2 = 課金経路が subscription と確認できない /
    4 = 隔離の外に新しい file。meta.json は rc に関わらず書く。"""
    meta = _read_meta_tsv(a.get("meta_tsv"))
    _collect_artifacts(a, meta)
    parsed = _collect_calls(a, meta)
    billing_ok = (
        parsed["billing"] == [BILLING_SUBSCRIPTION] and meta.get("api_key_source") == "none"
    )
    meta["billing_ok"] = billing_ok
    isolation_ok = _check_isolation(a, meta)
    meta["isolation_ok"] = isolation_ok
    meta["valid"] = billing_ok and isolation_ok
    _write_json(os.path.join(a["out"], "meta.json"), meta)
    if not billing_ok:
        return RC_BILLING_INVALID, meta
    if not isolation_ok:
        return RC_ISOLATION, meta
    return RC_OK, meta


_COLLECT_KEYS = (
    "proj",
    "out",
    "line",
    "date",
    "report_dir",
    "real_report_dir",
    "marker",
    "main",
    "target",
    "meta_tsv",
)


def cmd_collect(argv):
    a = {}
    it = iter(argv)
    for flag in it:
        key = flag.lstrip("-").replace("-", "_")
        if key not in _COLLECT_KEYS:
            print(f"collect: unknown flag {flag}", file=sys.stderr)
            return 64
        a[key] = next(it, "")
    missing = [k for k in ("proj", "out", "line", "date", "report_dir", "marker") if not a.get(k)]
    if missing:
        print(f"collect: missing {', '.join(missing)}", file=sys.stderr)
        return 64
    a.setdefault("real_report_dir", "")
    rc, meta = collect(a)
    print(
        f"billing_ok={int(meta['billing_ok'])} isolation_ok={int(meta['isolation_ok'])} "
        f"note={meta.get('note_name') or '-'} violations={len(meta['isolation']['violations'])}"
    )
    for v in meta["isolation"]["violations"][:20]:
        print(f"  newer than run start: {v}", file=sys.stderr)
    return rc


COMMANDS = {
    "rewrite-config": cmd_rewrite_config,
    "line-history": cmd_line_history,
    "api-key-source": cmd_api_key_source,
    "collect": cmd_collect,
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        print(f"usage: sandbox_lib.py <{' | '.join(COMMANDS)}> [args]", file=sys.stderr)
        return 64
    return COMMANDS[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
