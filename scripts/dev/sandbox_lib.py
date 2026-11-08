#!/usr/bin/env python3
"""sandbox_lib — scripts/dev/sandbox-run.sh の Python 側 (stdlib のみ、dev 専用)。

sandbox-run.sh は本番の scripts/daily-research.sh を、run ごとに作る PROJECT_DIR と隔離 vault の中で
1 line だけ回す。この module はその前後の、shell で書くと壊れやすい部分を持つ:

- rewrite-config: MAIN の config.toml を写し、[billing] mode・env_file と [general] vault_path だけを
  書き換える。書き換え後を tomllib で読み直し、その 3 値以外が元と一致することを検査する (一致しなければ
  書かない)
- line-history: past_topics.json から 1 line 分 (aliases を含む) の履歴を抜き出す (eval の重複判定用)
- auth-probe: claude -p --output-format stream-json を起動し、init event の apiKeySource を読んだ時点で
  止める ("none" = OAuth = サブスク。key の経路なら "ANTHROPIC_API_KEY" 等)。timeout 付き
- collect: run 後の成果物を出力 dir に集め、meta.json を書き、課金経路と隔離を検査する

本番の scripts/lib/ は import しない — 試す側のコード (git ref / 作業ツリー) が変わっても、道具の
挙動は変わらないようにする。

型: dr_pipeline.py と同じ規約 — 引数と戻り値を注釈し、JSON / TOML 由来の値は object /
dict[str, object] で受ける (Any は使わない。ruff ANN が tests の外で検査する)。
"""

import json
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import tomllib
from collections.abc import Callable
from datetime import datetime
from typing import TypedDict

BILLING_SUBSCRIPTION = "subscription"

# collect の終了コード (sandbox-run.sh が自分の終了コードに写す)
RC_OK = 0
RC_BILLING_INVALID = 2
RC_ISOLATION = 4

_SECTION_RE = re.compile(r"^\s*\[\s*([^\[\]]+?)\s*\]\s*(#.*)?$")
_ARRAY_TABLE_RE = re.compile(r"^\s*\[\[")
_LOG_TS_RE = re.compile(r"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] ")


# --- rewrite-config -------------------------------------------------------------------


def _toml_str(value: str) -> str:
    """TOML の basic string。JSON の escape は TOML basic string の部分集合として有効。"""
    return json.dumps(value, ensure_ascii=False)


def _set_key(lines: list[str], section: str, key: str, value_literal: str) -> list[str]:
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


def rewrite_config_text(text: str, vault_path: str, env_file: str) -> str:
    """config.toml の本文を、billing.mode = subscription / billing.env_file = env_file /
    general.vault_path = vault_path に書き換えた本文を返す。他の値は保つ。検査に落ちたら ValueError。
    env_file は存在しない path を渡す: 試すコードの billing.sh が mode を無視して key を読む退行を
    しても、本物の key file に届かない (既定値 ~/.config/daily-research/env も本物を指しうるので、
    元の config に env_file が無くても書く)。"""
    original = tomllib.loads(text)
    lines = text.splitlines()
    lines = _set_key(lines, "billing", "mode", _toml_str(BILLING_SUBSCRIPTION))
    lines = _set_key(lines, "billing", "env_file", _toml_str(env_file))
    lines = _set_key(lines, "general", "vault_path", _toml_str(vault_path))
    new_text = "\n".join(lines) + "\n"
    rewritten = tomllib.loads(new_text)
    expected = json.loads(json.dumps(original))
    expected.setdefault("billing", {})["mode"] = BILLING_SUBSCRIPTION
    expected["billing"]["env_file"] = env_file
    expected.setdefault("general", {})["vault_path"] = vault_path
    if json.loads(json.dumps(rewritten)) != expected:
        raise ValueError(
            "rewritten config differs from the original beyond billing.mode / env_file / vault_path"
        )
    return new_text


def cmd_rewrite_config(argv: list[str]) -> int:
    if len(argv) != 4:
        print(
            "usage: rewrite-config <src_config> <dst_config> <vault_path> <env_file>",
            file=sys.stderr,
        )
        return 64
    src, dst, vault, env_file = argv
    if os.path.exists(env_file):
        print(f"rewrite-config: env_file must not exist: {env_file}", file=sys.stderr)
        return 1
    with open(src, encoding="utf-8") as f:
        text = f.read()
    try:
        new_text = rewrite_config_text(text, vault, env_file)
    except (ValueError, tomllib.TOMLDecodeError) as e:
        print(f"rewrite-config: {e}", file=sys.stderr)
        return 1
    with open(dst, "w", encoding="utf-8") as f:
        f.write(new_text)
    os.chmod(dst, 0o600)
    return 0


# --- line-history ---------------------------------------------------------------------


def line_history(
    topics: list[object], tracks: dict[str, object], line: str
) -> list[dict[str, object]]:
    """past_topics の topics から line (と aliases) の entry を日付順に返す。"""
    track = tracks.get(line)
    aliases = track.get("aliases") if isinstance(track, dict) else None
    names = {line, *(aliases if isinstance(aliases, list) else [])}
    items = [t for t in topics if isinstance(t, dict) and t.get("track") in names]
    return sorted(items, key=lambda t: str(t.get("date", "")))


def cmd_line_history(argv: list[str]) -> int:
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


# --- auth-probe -----------------------------------------------------------------------

# claude の stream-json init event で認証の経路を表すキー ("none" = OAuth)
INIT_AUTH_FIELD = "apiKeySource"
# 呼び出しの result JSON にだけ出る OAuth の印。as-of 2026-11-08 (claude 2.1.319) の実測: api 課金の
# 本番 result 64 件 (2026-10-30〜11-08 のログ) に 0 件、サブスクの sandbox result 4 件に 4 件。
# 版が変わって消えたら、collect は run を無効の側に倒す (課金経路を確かめられない run を有効にしない)
OAUTH_RESULT_FIELD = "credential_expires_at"
AUTH_PROBE_TIMEOUT_S = 60


def init_auth_source(raw: str) -> str | None:
    """stream-json の 1 行が init event なら INIT_AUTH_FIELD の値 (str)、そうでなければ None。"""
    raw = raw.strip()
    if not raw.startswith("{"):
        return None
    try:
        d = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if isinstance(d, dict) and d.get("type") == "system" and d.get("subtype") == "init":
        return str(d.get(INIT_AUTH_FIELD, ""))
    return None


def _stop_group(proc: "subprocess.Popen[str]") -> None:
    """proc の process group (start_new_session で作ったもの) を止める: SIGTERM → leader を最大 3 秒待つ →
    group の残りを SIGKILL。leader が止まった後も SIGKILL を送るのは、SIGTERM と同時に fork された子が
    signal を受けずに group に残るから (実測: mock の sleep が孤児で残った)。"""

    def signal_group(sig: signal.Signals) -> None:
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass  # ESRCH = group が空。macOS は zombie だけの group に EPERM を返す

    if proc.poll() is None:
        signal_group(signal.SIGTERM)
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
    signal_group(signal.SIGKILL)
    proc.wait()


def auth_probe(
    cmd: list[str], cwd: str, timeout_s: float = AUTH_PROBE_TIMEOUT_S
) -> tuple[str, str]:
    """cmd (claude -p … --output-format stream-json --verbose) を cwd で起動し、最初の init event の
    INIT_AUTH_FIELD を読んだ時点で process group ごと止める。init はセッションの最初の event で、
    model の応答 (result) を待たない — key が混じった環境でも、拒否の前に 1 回分の応答を生成させない。
    timeout_s までに init が来なければ止める。戻り値は (value, reason)、reason は
    "init" / "timeout" / "exited-without-init"。"""
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        text=True,
        errors="replace",
    )
    lines: queue.Queue[str | None] = queue.Queue()

    def pump() -> None:
        for raw in proc.stdout or ():
            lines.put(raw)
        lines.put(None)

    threading.Thread(target=pump, daemon=True).start()
    deadline = time.monotonic() + timeout_s
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return "", "timeout"
            try:
                raw = lines.get(timeout=remaining)
            except queue.Empty:
                return "", "timeout"
            if raw is None:
                return "", "exited-without-init"
            value = init_auth_source(raw)
            if value is not None:
                return value, "init"
    finally:
        _stop_group(proc)


def cmd_auth_probe(argv: list[str]) -> int:
    """auth-probe --cwd <dir> [--timeout <s>] -- <cmd…>。stdout に "value<TAB>reason" を 1 行出す。"""
    usage = "usage: auth-probe --cwd <dir> [--timeout <seconds>] -- <command…>"
    if "--" not in argv:
        print(usage, file=sys.stderr)
        return 64
    i = argv.index("--")
    opts, cmd = argv[:i], argv[i + 1 :]
    cwd: str | None = None
    timeout_s = float(AUTH_PROBE_TIMEOUT_S)
    it = iter(opts)
    for flag in it:
        if flag == "--cwd":
            cwd = next(it, None)
        elif flag == "--timeout":
            timeout_s = float(next(it, "0") or 0)
        else:
            print(usage, file=sys.stderr)
            return 64
    if not cmd or not cwd or not os.path.isdir(cwd) or timeout_s <= 0:
        print(usage, file=sys.stderr)
        return 64
    try:
        value, reason = auth_probe(cmd, cwd, timeout_s)
    except OSError as e:
        value, reason = "", f"spawn-failed ({type(e).__name__})"
    print(f"{value}\t{reason}")
    return 0


class ParsedLog(TypedDict):
    """parse_log の戻り値。callN は result JSON、callN_expected はログの制御の行から数えた呼び出し回数。"""

    billing: list[str]
    call1: list[dict[str, object]]
    call2: list[dict[str, object]]
    call1_expected: int
    call2_expected: int
    clarity_ts: str | None
    clarity_note: str | None


def call_auth(parsed: ParsedLog) -> list[dict[str, object]]:
    """呼1 / 呼2 の result JSON ごとの課金経路の印。ok = INIT_AUTH_FIELD が無いか "none"、かつ
    OAUTH_RESULT_FIELD がある。本番の呼び出しは --output-format json なので init event は残らず、
    result に INIT_AUTH_FIELD が出る版でだけそれも見る。"""
    rows: list[dict[str, object]] = []
    for call in ("call1", "call2"):
        results = parsed["call1"] if call == "call1" else parsed["call2"]
        for i, d in enumerate(results, 1):
            source = d.get(INIT_AUTH_FIELD)
            marker = OAUTH_RESULT_FIELD in d
            rows.append(
                {
                    "call": f"{call}#{i}",
                    INIT_AUTH_FIELD: source,
                    "oauth_marker": marker,
                    "ok": source in (None, "none") and marker,
                }
            )
    return rows


def call_evidence(parsed: ParsedLog) -> dict[str, object]:
    """呼び出しの回数 (ログの制御の行から数えた期待値) と result JSON の件数を突き合わせる。timeout で
    kill された呼び出しは result を残さないので、件数が足りなければ課金経路の証拠を欠いた呼び出しがある
    (call_auth は在る result しか見ないので、0 件でも ok になる)。"""
    counts = {
        "call1": {"expected": parsed["call1_expected"], "results": len(parsed["call1"])},
        "call2": {"expected": parsed["call2_expected"], "results": len(parsed["call2"])},
    }
    ok = all(c["expected"] == c["results"] for c in counts.values())
    return {**counts, "ok": ok}


# --- collect --------------------------------------------------------------------------

# daily-research.sh の呼1 の attempt loop が書く行 (期待する呼び出し回数を数える)。cwd が無い line は
# loop に入らず 0 回、入れば 1 回 + retry の行ごとに 1 回、retry を見送った行ごとに -1 回。
# 試すコードがこの文言を変えると件数が合わず run は無効の側に倒れる (課金経路を確かめられない run を
# 有効にしない)
_CALL1_RETRY = "— retrying once"
_CALL1_RETRY_SKIPPED = ("skipping retry", "retry skipped")
_CALL1_LINE_SKIPPED = " を skip"


def parse_log(text: str) -> ParsedLog:
    """当日ログから呼1 / 呼2 の result JSON・期待する呼び出し回数・課金経路の行を取り出す。
    daily-research.sh は result JSON を 1 行で log へ echo し、その前に "=== Line:" /
    "=== Clarity pass: <note> ===" の行を書く。直前の marker で呼1 / 呼2 を振り分ける。"""
    out: ParsedLog = {
        "billing": [],
        "call1": [],
        "call2": [],
        "call1_expected": 0,
        "call2_expected": 0,
        "clarity_ts": None,
        "clarity_note": None,
    }
    section = None
    for line in text.splitlines():
        if "] Billing: " in line:
            out["billing"].append(line.split("] Billing: ", 1)[1].split(" ", 1)[0])
        if "] === Line: " in line:
            section = "call1"
            out["call1_expected"] += 1
        elif "] === Clarity pass: " in line:
            section = "call2"
            out["call2_expected"] += 1
            m = _LOG_TS_RE.match(line)
            out["clarity_ts"] = m.group(1) if m else None
            out["clarity_note"] = line.split("] === Clarity pass: ", 1)[1].rstrip(" =")
        elif section == "call1" and "] WARN: " in line:
            if line.rstrip().endswith(_CALL1_LINE_SKIPPED):
                out["call1_expected"] -= 1
            elif _CALL1_RETRY in line:
                out["call1_expected"] += 1
            elif any(s in line for s in _CALL1_RETRY_SKIPPED):
                out["call1_expected"] -= 1
        stripped = line.strip()
        if section and stripped[:1] in ("{", "["):
            try:
                d = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            if isinstance(d, list):
                d = next((e for e in d if isinstance(e, dict) and e.get("type") == "result"), {})
            if isinstance(d, dict) and d.get("type") == "result":
                (out["call1"] if section == "call1" else out["call2"]).append(d)
    return out


def newer_files(
    root: str, marker_mtime: float, skip_dirs: tuple[str, ...] = (".git",)
) -> list[str]:
    """root 以下で mtime が marker より新しい file / dir の path を返す (無ければ [])。"""
    found: list[str] = []
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


def _copy(src: str, dst: str) -> bool:
    if src and os.path.isfile(src):
        shutil.copy2(src, dst)
        return True
    return False


def _write_json(path: str, obj: object) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
        f.write("\n")


def _read_meta_tsv(path: str | None) -> dict[str, object]:
    """sandbox-run.sh が書いた "key<TAB>value" 行を dict にする。key の接尾辞 :int / :json で型を付ける。"""
    meta: dict[str, object] = {}
    if not path or not os.path.exists(path):
        return meta
    with open(path, encoding="utf-8") as f:
        for raw in f.read().splitlines():
            key, sep, text = raw.partition("\t")
            if not sep:
                continue
            value: object = text
            if key.endswith(":int"):
                key, value = key[:-4], int(text) if re.fullmatch(r"-?\d+", text) else None
            elif key.endswith(":json"):
                key, value = key[:-5], json.loads(text) if text else None
            meta[key] = value
    return meta


def _collect_artifacts(a: dict[str, str], meta: dict[str, object]) -> None:
    """成果物を out に写し、meta に名前と件数を書く。"""
    runs = os.path.join(a["proj"], "state", a["line"], "runs")
    date, line, out = a["date"], a["line"], a["out"]
    notes: list[str] = []
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


def _collect_calls(a: dict[str, str], meta: dict[str, object]) -> ParsedLog:
    """ログから呼1 / 呼2 の result JSON を写し、課金経路と draft の鮮度を meta に書く。"""
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


def _check_isolation(a: dict[str, str], meta: dict[str, object]) -> bool:
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
    violations: list[str] = []
    for r in roots:
        if r:
            violations += newer_files(r, marker)
    meta["isolation"] = {"checked": [r for r in roots if r], "violations": violations}
    return not violations


def collect(a: dict[str, str]) -> tuple[int, dict[str, object]]:
    """run 後の集約。戻り値は (rc, meta)。rc: 0 = 有効 / 2 = 課金経路が subscription と確認できない /
    4 = 隔離の外に新しい file。meta.json は rc に関わらず書く。
    課金経路は独立な証拠の積: config 由来のログ行 (Billing:)・事前 probe の init event・
    呼び出しごとの result JSON の印 (call_auth)・呼び出しの回数と result の件数の一致 (call_evidence)。"""
    meta = _read_meta_tsv(a.get("meta_tsv"))
    _collect_artifacts(a, meta)
    parsed = _collect_calls(a, meta)
    auth_rows = call_auth(parsed)
    evidence = call_evidence(parsed)
    meta["call_auth"] = auth_rows
    meta["call_evidence"] = evidence
    billing_ok = (
        parsed["billing"] == [BILLING_SUBSCRIPTION]
        and meta.get("api_key_source") == "none"
        and all(r["ok"] for r in auth_rows)
        and evidence["ok"] is True
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


def cmd_collect(argv: list[str]) -> int:
    a: dict[str, str] = {}
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
    isolation = meta["isolation"]
    violations = isolation.get("violations", []) if isinstance(isolation, dict) else []
    print(
        f"billing_ok={int(meta['billing_ok'] is True)} isolation_ok={int(meta['isolation_ok'] is True)} "
        f"note={meta.get('note_name') or '-'} violations={len(violations)}"
    )
    for v in violations[:20]:
        print(f"  newer than run start: {v}", file=sys.stderr)
    return rc


COMMANDS: dict[str, Callable[[list[str]], int]] = {
    "rewrite-config": cmd_rewrite_config,
    "line-history": cmd_line_history,
    "auth-probe": cmd_auth_probe,
    "collect": cmd_collect,
}


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in COMMANDS:
        print(f"usage: sandbox_lib.py <{' | '.join(COMMANDS)}> [args]", file=sys.stderr)
        return 64
    return COMMANDS[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
