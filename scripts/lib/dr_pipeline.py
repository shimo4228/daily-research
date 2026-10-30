#!/usr/bin/env python3
"""dr_pipeline — daily-research の JSON/TOML 解析層を集約した単一モジュール。

これまで daily-research.sh に散在していた `python3 -c "..."` / heredoc を
subcommand に置き換える parser-of-record。test も本モジュールだけを対象にすれば
よくなり、source と test のコピペ drift (旧 test-log-summary.bats) を根絶する。

呼び出し:  python3 scripts/lib/dr_pipeline.py <subcommand> [args]
依存:      stdlib のみ (json / tomllib / re / collections)。pip 依存なし。
           config.toml 解析に python>=3.11 の tomllib を使う (tomli fallback あり)。
"""

import json
import re
import sys


def _tomllib():
    try:
        import tomllib

        return tomllib
    except ImportError:  # python < 3.11
        import tomli as tomllib

        return tomllib


def _result_dict(raw):
    """claude -p の出力が array (stream/json) なら result イベントを、
    dict ならそのまま返す。result が無ければ {}。"""
    if isinstance(raw, list):
        return next((e for e in raw if isinstance(e, dict) and e.get("type") == "result"), {})
    return raw


# --- config helpers: 1 line = N repos schema の解析 + 旧 schema 検出 guard ---
_TRACK_NAME_RE = re.compile(r"[A-Za-z0-9_-]+")

# [tracks.<x>].mode (ADR-0018)。"repo" (既定) = cwd を target_repo にして repo の運用文脈の
# 中で走る line (ADR-0008)。"ecosystem" = 接地 repo を持たず、外部エコシステムの変化そのものを
# 観測する line — cwd は state/<line>、プロトコルは prompts/ecosystem-research-protocol.md。
# invariant: ecosystem line は repo 文脈を要求できない (repos / context_files は schema で拒否)。
MODE_REPO = "repo"
MODE_ECOSYSTEM = "ecosystem"
_TRACK_MODES = (MODE_REPO, MODE_ECOSYSTEM)
_ECOSYSTEM_FORBIDDEN_KEYS = ("repos", "context_files")


def _track_mode(track_cfg):
    """line の mode を返す。_load_tracks が enum 検証済みの値だけを通す。"""
    return track_cfg.get("mode", MODE_REPO)


def _lines_per_day(cfg):
    """[general].lines_per_day (1 日に走らせる輪番 line 数、ADR-0017)。既定 1。
    int >= 1 のみ許す — bool は int の subclass なので明示的に除く
    (lines_per_day = true が 1 として黙って通る事故を防ぐ)。"""
    k = cfg.get("general", {}).get("lines_per_day", 1)
    if isinstance(k, bool) or not isinstance(k, int) or k < 1:
        raise ValueError(f"[general].lines_per_day must be an integer >= 1, got {k!r}")
    return k


def _load_tracks(config_path):
    """config.toml を読み (cfg, tracks) を返す。旧 schema (tracks.X 直下に
    target_repo) を検出したら ValueError — 再編後のコードが旧 config のまま
    朝の実行を迎えて静かに誤動作する事故を防ぐ。"""
    tomllib = _tomllib()
    with open(config_path, "rb") as f:
        cfg = tomllib.load(f)
    tracks = cfg.get("tracks", {})
    _lines_per_day(cfg)  # 型違反は起動時の schema check で fail-fast
    for name, v in tracks.items():
        # track 名は state/<track> のパス、receipt の report 名検証、呼2 の
        # --allowedTools に入る。区切り文字 (カンマ・スラッシュ等) を持たせない。
        if not _TRACK_NAME_RE.fullmatch(name):
            raise ValueError(f"track name must match [A-Za-z0-9_-]+, got {name!r}")
        if isinstance(v, dict) and "target_repo" in v:
            raise ValueError(
                f"config uses the legacy schema: target_repo directly under [tracks.{name}]. "
                f"Migrate to [[tracks.{name}.repos]] entries (see config.example.toml)"
            )
        # daily は bool 限定。TOML で daily = "false" と書くと bool("false") is True で
        # 毎日実行が黙って有効になる事故を、起動時の schema check で fail-fast に落とす。
        if isinstance(v, dict) and "daily" in v and not isinstance(v["daily"], bool):
            raise ValueError(
                f"[tracks.{name}].daily must be a boolean (true/false), got {v['daily']!r}"
            )
        # template は project 相対パスの文字列限定 (per-track テンプレート上書き)。
        if isinstance(v, dict) and "template" in v and not isinstance(v["template"], str):
            raise ValueError(
                f"[tracks.{name}].template must be a string path, got {v['template']!r}"
            )
        # mode は enum 限定 (bool / int / 未知の語は fail-fast)。ecosystem line に repo 文脈の
        # key を書いた config は、どちらの実行形か曖昧なまま朝を迎えるので起動時に落とす。
        if isinstance(v, dict) and "mode" in v:
            if not isinstance(v["mode"], str) or v["mode"] not in _TRACK_MODES:
                raise ValueError(
                    f"[tracks.{name}].mode must be one of {_TRACK_MODES}, got {v['mode']!r}"
                )
            if v["mode"] == MODE_ECOSYSTEM:
                for key in _ECOSYSTEM_FORBIDDEN_KEYS:
                    if key in v:
                        raise ValueError(
                            f'[tracks.{name}] has mode = "ecosystem" and must not set '
                            f"{key} (an ecosystem line has no target repo context)"
                        )
    return cfg, tracks


def _track_repos(track_cfg):
    """line 定義の repos 配列を返す。無ければ []。repo mode で repos が空の line は
    行を出さない (実行されない)。repo を持たない line は mode = "ecosystem" で宣言する。"""
    repos = track_cfg.get("repos", [])
    return repos if isinstance(repos, list) else []


def _track_rows(tracks):
    """全 line の (track, key, target_repo, daily) 行を config 記述順で返す。
    tracks / rotation-pick が共有する行構築の正本 — 輪番の単位・順序は
    この関数が定義する (二重実装で周期が黙って乖離するのを防ぐ)。
    daily = true の line は毎日実行され、輪番の周期には入らない。
    ecosystem line (ADR-0018) は key = track 名、target_repo = "" の 1 行 — 3 列の形を保ち、
    実行形 (cwd / プロトコル) は呼び出し側が [tracks.<x>].mode から決める。"""
    rows = []
    for track, v in tracks.items():
        daily = bool(v.get("daily"))
        if _track_mode(v) == MODE_ECOSYSTEM:
            rows.append((track, track, "", daily))
            continue
        for r in _track_repos(v):
            key = r.get("key")
            repo = r.get("target_repo")
            if key and repo:
                rows.append((track, key, repo, daily))
    return rows


def _searches(d):
    """claude -p result dict から Web 検索回数を返す。
    実出力 (2026-09 時点) は WebSearch を modelUsage.<model>.webSearchRequests に
    計上し usage.server_tool_use.web_search_requests は 0 のまま — server_tool_use
    だけを見ると検索した run も 0 になる。tool_counts は旧形式 / test mock の表現
    (WebSearch + WebFetch)。優先: tool_counts > modelUsage 合算 > server_tool_use。"""
    d = _result_dict(d) or {}
    if not isinstance(d, dict):
        return 0

    def _int(v):
        return v if isinstance(v, int) and not isinstance(v, bool) and v > 0 else 0

    tc = d.get("tool_counts")
    if isinstance(tc, dict):
        return _int(tc.get("WebSearch", 0)) + _int(tc.get("WebFetch", 0))
    mu = d.get("modelUsage")
    if isinstance(mu, dict):
        total = sum(_int(m.get("webSearchRequests", 0)) for m in mu.values() if isinstance(m, dict))
        if total:
            return total
    stu = (d.get("usage") or {}).get("server_tool_use") or {}
    return _int(stu.get("web_search_requests", 0)) if isinstance(stu, dict) else 0


# --- searches: stdin の claude -p JSON から検索回数を 1 行で出力 (quiet-suspect 判定用) ---
# 解析失敗は 0 (常に rc 0)。
def cmd_searches(argv):
    try:
        print(_searches(json.loads(sys.stdin.read() or "null")))
    except (ValueError, AttributeError, TypeError):  # 非 JSON / 想定外の型
        print(0)
    return 0


# --- error-fields: stdin JSON から "api_error_status<TAB>is_error<TAB>kind" を出力 ---
# kind は課金系の失敗の種類: "billing" = 429 (rate limit) / 402 / クレジット残高不足 —
# 再試行で踏み抜かず止める (rules: debugging.md の policy signal)。"budget" = 呼び出しごとの
# --max-budget-usd に到達 (subtype error_max_budget_usd)。どちらでもなければ空。
_CREDIT_RE = re.compile(r"credit balance|insufficient.{0,20}credit", re.IGNORECASE)


def _error_kind(d):
    if d.get("subtype") == "error_max_budget_usd":
        return "budget"
    code = d.get("api_error_status")
    if code in (402, 429):
        return "billing"
    if d.get("is_error") and _CREDIT_RE.search(str(d.get("result") or "")):
        return "billing"
    return ""


def cmd_error_fields(argv):
    try:
        d = json.loads(sys.stdin.read() or "null")
        d = _result_dict(d) or {}
        code = d.get("api_error_status")
        code = "" if code is None else code
        print(f"{code}\t{str(bool(d.get('is_error'))).lower()}\t{_error_kind(d)}")
    except Exception:  # noqa: BLE001 — 解析失敗は常に parse-fail 行で返す (auth 判定は non-fatal)
        print("\tparse-fail\t")
    return 0


# --- log-summary <label>: claude -p JSON からサマリー行を出力 ---
def cmd_log_summary(argv):
    label = argv[0] if argv else "?"
    try:
        raw = json.loads(sys.stdin.read())
        d = _result_dict(raw)
        cost = d.get("total_cost_usd", 0)
        turns = d.get("num_turns", 0)
        dur = round(d.get("duration_ms", 0) / 1000)
        inp = d.get("usage", {}).get("input_tokens", 0)
        out = d.get("usage", {}).get("output_tokens", 0)
        searches = _searches(d)
        tool_str = f" searches={searches}" if searches else ""
        print(
            f"SUMMARY {label}: cost=${cost:.4f} turns={turns} duration={dur}s tokens_in={inp} tokens_out={out}{tool_str}"
        )
    except Exception as e:  # noqa: BLE001 — ログ用サマリーは失敗しても 1 行を返す
        print(f"SUMMARY {label}: (parse error: {e})")
    return 0


# --- vault-path [config_path]: config.toml の [general].vault_path を出力 ---
def cmd_vault_path(argv):
    config_path = argv[0] if argv else "config.toml"
    tomllib = _tomllib()
    with open(config_path, "rb") as f:
        print(tomllib.load(f).get("general", {}).get("vault_path", ""))
    return 0


# --- report-dir [config_path]: レポート出力先 {vault_path}/{output_dir} を出力 ---
# どちらか欠けている config では空文字を出力する (呼び出し側はゲートを skip する)。
def cmd_report_dir(argv):
    config_path = argv[0] if argv else "config.toml"
    tomllib = _tomllib()
    with open(config_path, "rb") as f:
        general = tomllib.load(f).get("general", {})
    vault = general.get("vault_path", "")
    output_dir = general.get("output_dir", "")
    print(f"{vault}/{output_dir}" if vault and output_dir else "")
    return 0


# --- template-path <config_path> <track>: line のレポートテンプレート相対パスを出力 ---
# [tracks.<x>].template があればそれ、無ければ既定の templates/report-template.md。
# パスは config 記述のまま (project 相対) — 存在検査は呼び出し側 (shell) が cat の
# 失敗として検出し、既定テンプレートへ fallback する。
DEFAULT_TEMPLATE = "templates/report-template.md"


def cmd_template_path(argv):
    if len(argv) < 2:
        print("usage: template-path <config_path> <track>", file=sys.stderr)
        return 64
    config_path, track = argv[:2]
    try:
        _, tracks = _load_tracks(config_path)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1
    v = tracks.get(track)
    if not isinstance(v, dict):
        print(f"unknown track: {track}", file=sys.stderr)
        return 1
    print(v.get("template") or DEFAULT_TEMPLATE)
    return 0


# --- tracks [config_path]: "line<TAB>repo_key<TAB>target_repo" を出力 (1 repo 1 行) ---
def cmd_tracks(argv):
    config_path = argv[0] if argv else "config.toml"
    try:
        _, tracks = _load_tracks(config_path)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1
    for track, key, repo, _daily in _track_rows(tracks):
        print(f"{track}\t{key}\t{repo}")
    return 0


# --- rotation-pick <config_path> <date>: 当日担当 line 群を決定論選択して出力 ---
# 出力形式は tracks と同じ "line<TAB>repo_key<TAB>target_repo"。先頭は非 daily 行の
# window 輪番 (ADR-0017): k = [general].lines_per_day、n = 非 daily 行数、
# start = (day * k) % n、rotating[(start + i) % n] for i < min(k, n)。
# day = date.toordinal() (proleptic Gregorian 序数 — Unix epoch 日で再実装すると
# 位相がずれるので注意)。窓は毎日 k 行ずつ進むので、k と n が互いに素なら n 日で
# 各行がちょうど k 回選ばれる。k = 1 は旧 day % n と同一位相 (ADR-0010)。
# 以降に daily = true の line の行が config 記述順で続く (daily line は毎日実行され、
# 輪番の周期を変えない)。全行 daily の config では輪番行なしで daily 行のみ。
# state ファイル不要で、同日の再実行は常に同じ行群を返す (冪等)。順序は config.toml の
# 記述順 (tomllib は挿入順を保持する)。
# 注意: 輪番の単位は line ではなく repos 行 — 現行 config は 1 line = 1 repo なので
# 一致するが、1 line に複数 repos を書くとその line の頻度が上がる。
def cmd_rotation_pick(argv):
    from datetime import date as _date

    if len(argv) < 2:
        print("usage: rotation-pick <config_path> <date>", file=sys.stderr)
        return 64
    config_path, date_s = argv[:2]
    try:
        cfg, tracks = _load_tracks(config_path)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1
    rows = _track_rows(tracks)
    if not rows:
        print("rotation-pick: no lines in config", file=sys.stderr)
        return 1
    try:
        day = _date.fromisoformat(date_s).toordinal()
    except ValueError:
        print(f"rotation-pick: invalid date {date_s!r}", file=sys.stderr)
        return 64
    rotating = [r for r in rows if not r[3]]
    daily = [r for r in rows if r[3]]
    picked = []
    if rotating:
        k, n = _lines_per_day(cfg), len(rotating)
        start = (day * k) % n
        picked.extend(rotating[(start + i) % n] for i in range(min(k, n)))
    picked.extend(daily)
    for track, key, repo, _d in picked:
        print(f"{track}\t{key}\t{repo}")
    return 0


# --- past-themes [past_topics_path] [config_path]: line 別直近 10 件の履歴を出力 ---
def cmd_past_themes(argv):
    from collections import defaultdict

    past_path = argv[0] if len(argv) >= 1 else "past_topics.json"
    config_path = argv[1] if len(argv) >= 2 else "config.toml"

    try:
        with open(past_path) as f:
            topics = json.load(f).get("topics", [])
    except (FileNotFoundError, json.JSONDecodeError):
        topics = []

    try:
        _, tracks = _load_tracks(config_path)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1

    # 旧 track 名 (aliases) を新 line に写像し、再編後も履歴 dedup を継続する
    line_of = {}
    for line, v in tracks.items():
        line_of[line] = line
        for alias in v.get("aliases", []):
            line_of.setdefault(alias, line)

    by_line = defaultdict(list)
    for t in topics:
        line = line_of.get(t.get("track"))
        if line and (t.get("title") or t.get("question")):
            by_line[line].append(t)

    print("=== 過去テーマ履歴 (line 別直近 10 件、問い単位) ===")
    print("各行は「問い — 答えの範囲 (answer_scope)」。判定は問い単位で行う:")
    print("- 同じ問い + 同じ答え = 再選定禁止")
    print("- 同じ問い + 新証拠 = 更新として可 (何が新しい証拠かを本文に書く)")
    print("- 同じ topic + 別の問い = 可")
    print()
    for line, v in tracks.items():
        items = by_line.get(line, [])
        if not items:
            continue
        aliases = [a for a in v.get("aliases", []) if a != line]
        suffix = f" (旧 track: {', '.join(aliases)} を含む)" if aliases else ""
        items.sort(key=lambda t: t.get("date", ""))
        print(f"Track: {line}{suffix}")
        for t in items[-10:]:
            head = str(t.get("question") or t.get("title"))
            head = head[:120] + ("…" if len(head) > 120 else "")
            scope = t.get("answer_scope")
            suffix = f" — {str(scope)[:120]}" if scope else ""
            print(f"  - {t.get('date', '?')} {head}{suffix}")
        print()
    return 0


# --- line-brief <config_path> <track>: per-repo 実行 (ADR-0008) のプロンプト注入用に
#     line 定義 (name / focus / sources / self_signals) を整形出力。context_files は
#     冒頭で読む文脈ではなく、テーマ選定後に読む候補として別節に出す (ADR-0017) ---
def cmd_line_brief(argv):
    if len(argv) < 2:
        print("usage: line-brief <config_path> <track>", file=sys.stderr)
        return 64
    config_path, track = argv[:2]
    try:
        cfg, tracks = _load_tracks(config_path)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1
    v = tracks.get(track)
    if not isinstance(v, dict):
        print(f"unknown track: {track}", file=sys.stderr)
        return 1

    print("## Line 定義 (config)")
    print()
    if _track_mode(v) == MODE_ECOSYSTEM:
        print("- mode: ecosystem (接地 repo なし — 観測対象は外部エコシステムの変化そのもの)")
    if v.get("name"):
        print(f"- name: {v['name']}")
    if v.get("focus"):
        print(f"- focus: {v['focus']}")
    sources = v.get("sources") or []
    if sources:
        print("- 探索の起点 (sources):")
        for s in sources:
            print(f"  - {s}")
    signals = cfg.get("general", {}).get("self_signals") or []
    if signals:
        print("- 自己シグナル (自己汚染ガード — これらに合致する成果物を「外部シグナル」")
        print("  として数えない。第三者による言及・採用の観測は正当):")
        for s in signals:
            print(f"  - {s}")
    ctx = v.get("context_files") or []
    if ctx:
        print()
        print("## 選定後に読む候補 (Step 3b)")
        print()
        print("テーマ (問い) を選んだ後、含意の前提確認に関係するものだけを読む。")
        print("存在しないものは skip してよい。")
        for c in ctx:
            print(f"- {c}")
    return 0


# --- receipt-read <path> <date> <track>: 呼1 の run receipt を検証して TSV 1 行で出力 ---
# stdout: "status<TAB>report<TAB>reason<TAB>reason_code" (report が null なら空欄)。
# 不正 (非 JSON / 非 object / status enum 外 / date・line 不一致 / report 名不正 /
# article・brief で report 無し) は stdout 空で rc 1 — shell の gate が line 失敗にする。
# report は model 由来文字列なので {date}_{track}_[A-Za-z0-9._-]+.md に限定する
# (パス区切り・カンマを通さない)。shell は report を allowedTools に埋めない
# (呼2 の対象は run スコープの find 結果) — ここでの検証は gate 判定用。
RECEIPT_STATUSES = ("article", "brief", "quiet", "hold")
# receipt (呼1 が state/<line>/runs/{date}.json に書く) のキーと順序。両プロトコルの receipt 例は
# この順で書く — tests/dr_pipeline_test.py がプロトコル本文と照合する (共有契約の正本)。
RECEIPT_KEYS = (
    "date",
    "line",
    "status",
    "report",
    "question",
    "reason",
    "reason_code",
    "answer_scope",
    "title",
)
REASON_CODES = ("no_new_evidence", "thin_material", "fetch_failed", "carry_over")
_CTRL_RE = re.compile(r"[\x00-\x1f\x7f]")


def cmd_receipt_read(argv):
    if len(argv) < 3:
        print("usage: receipt-read <path> <date> <track>", file=sys.stderr)
        return 64
    path, date_s, track = argv[:3]

    def bad(msg):
        print(f"receipt-read: {msg}", file=sys.stderr)
        return 1

    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError) as e:
        return bad(f"unreadable receipt: {e}")
    if not isinstance(d, dict):
        return bad("receipt is not a JSON object")
    status = d.get("status")
    if status not in RECEIPT_STATUSES:
        return bad(f"invalid status {status!r}")
    if "date" in d and d["date"] != date_s:
        return bad(f"date mismatch {d['date']!r} != {date_s!r}")
    if "line" in d and d["line"] != track:
        return bad(f"line mismatch {d['line']!r} != {track!r}")
    report = d.get("report")
    if report is None or report == "":
        report = ""
    elif not isinstance(report, str) or not re.fullmatch(
        rf"{re.escape(date_s)}_{re.escape(track)}_[A-Za-z0-9._-]+\.md", report
    ):
        return bad(f"invalid report name {report!r}")
    if status in ("article", "brief") and not report:
        return bad(f"status {status} requires report")
    reason = d.get("reason")
    reason = "" if reason is None else _CTRL_RE.sub(" ", str(reason))[:200]
    code = d.get("reason_code")
    code = code if code in REASON_CODES else "unspecified"
    print(f"{status}\t{report}\t{reason}\t{code}")
    return 0


# --- past-topics-append <past_path> <receipt_path> <date> <track> [report_basename] ---
# past_topics.json への追記 (ADR-0019 Decision 4)。orchestrator が receipt gate の成功後に呼ぶ。
# entry は読み手 cmd_past_themes が使うキーだけ。report_basename は gate が解決した run の
# ノート (quiet / hold は省略 → slug は空)。既存 file が壊れていたら書かずに rc 1 (run 開始時の
# 退避 past_topics.json.bak が残る)。receipt の欠けた項目は空文字 + stderr に WARN。
# 書き込みは同じ dir の一時 file → os.replace (途中で落ちても既存 file は壊れない)。
PAST_TOPIC_KEYS = ("date", "track", "title", "slug", "question", "answer_scope")
_PAST_TOPIC_FIELD_MAX = 300


def cmd_past_topics_append(argv):
    import os
    import tempfile

    if len(argv) < 4:
        print(
            "usage: past-topics-append <past_path> <receipt_path> <date> <track> [report]",
            file=sys.stderr,
        )
        return 64
    past_path, receipt_path, date_s, track = argv[:4]
    report = argv[4] if len(argv) >= 5 else ""

    def bad(msg):
        print(f"past-topics-append: {msg}", file=sys.stderr)
        return 1

    slug = ""
    if report:
        m = re.fullmatch(rf"{re.escape(date_s)}_{re.escape(track)}_([A-Za-z0-9._-]+)\.md", report)
        if not m:
            return bad(f"invalid report name {report!r}")
        slug = m.group(1)
    try:
        with open(receipt_path, encoding="utf-8") as f:
            rec = json.load(f)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError) as e:
        return bad(f"unreadable receipt: {e}")
    if not isinstance(rec, dict):
        return bad("receipt is not a JSON object")

    def field(name):
        v = rec.get(name)
        if v is None or v == "":
            print(f"past-topics-append: WARN receipt has no {name}", file=sys.stderr)
            return ""
        text = re.sub(r"\s+", " ", _CTRL_RE.sub(" ", str(v))).strip()
        return text[:_PAST_TOPIC_FIELD_MAX]

    entry = {
        "date": date_s,
        "track": track,
        "title": field("title"),
        "slug": slug,
        "question": field("question"),
        "answer_scope": field("answer_scope"),
    }

    if os.path.exists(past_path):
        try:
            with open(past_path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError, UnicodeDecodeError) as e:
            return bad(f"existing file unreadable, not writing: {e}")
        if not isinstance(data, dict) or not isinstance(data.get("topics"), list):
            return bad("existing file has no topics list, not writing")
    else:
        data = {"version": 1, "topics": []}
    data["topics"].append(entry)

    out_dir = os.path.dirname(os.path.abspath(past_path))
    fd, tmp = tempfile.mkstemp(prefix=".past_topics.", suffix=".tmp", dir=out_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp, past_path)
    except OSError as e:
        if os.path.exists(tmp):
            os.unlink(tmp)
        return bad(f"write failed: {e}")
    return 0


# --- verify-read [path]: 呼2 の verify.json を 1 行 JSON に正規化して出力 ---
# {supported, partial, unsupported, unverifiable, edits, ran}。各値は int >= 0
# (bool / 文字列 / 負値 / 小数は 0)。ファイル欠損・破損・非 object は全零 + ran:false。
# 常に rc 0 (計測は non-fatal)。
VERIFY_KEYS = ("supported", "partial", "unsupported", "unverifiable", "edits")


def _nonneg_int(v):
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else 0


def cmd_verify_read(argv):
    path = argv[0] if argv else ""
    d = None
    if path:
        try:
            with open(path) as f:
                d = json.load(f)
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            d = None
    ran = isinstance(d, dict)
    out = {k: _nonneg_int(d.get(k)) if ran else 0 for k in VERIFY_KEYS}
    out["ran"] = ran
    print(json.dumps(out))
    return 0


# --- config-get <config_path> <section.key> [default]: config の 1 値を出力 ---
# 値が無い・config が読めない場合は default (省略時は空行)。bool は true/false。
def cmd_config_get(argv):
    if len(argv) < 2:
        print("usage: config-get <config_path> <section.key> [default]", file=sys.stderr)
        return 64
    config_path, dotted = argv[:2]
    default = argv[2] if len(argv) >= 3 else ""
    try:
        tomllib = _tomllib()
        with open(config_path, "rb") as f:
            node = tomllib.load(f)
    except (OSError, ValueError):
        print(default)
        return 0
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            print(default)
            return 0
        node = node[part]
    if isinstance(node, bool):
        print("true" if node else "false")
    elif isinstance(node, (dict, list)):
        print(json.dumps(node, ensure_ascii=False))
    else:
        print(node)
    return 0


# === 自己改善ループ (ADR-0006): 計測の永続化と決定論 lint =====================
#
# consumer は人間 (/dr-review skill)。ここは判断材料の収集・整形のみを担い、
# LLM による品質再採点や自動改変は行わない。


def _pass_metrics(d):
    """claude -p result JSON から 1 pass 分の metric dict を抽出する。"""
    d = _result_dict(d) or {}
    return {
        "cost": round(float(d.get("total_cost_usd", 0) or 0), 4),
        "turns": int(d.get("num_turns", 0) or 0),
        "duration_s": round((d.get("duration_ms", 0) or 0) / 1000),
        "tokens_in": int(d.get("usage", {}).get("input_tokens", 0) or 0),
        "tokens_out": int(d.get("usage", {}).get("output_tokens", 0) or 0),
        "searches": _searches(d),
    }


def _load_metrics(metrics_path, include_test=False):
    """metrics.jsonl を list[dict] で返す。壊れた行は skip (収集は non-fatal)。

    source == "test" (DR_FORCE_TRACK / DR_ONLY_TRACK の試験 run) は既定で除く —
    expect-check / dr-review は本番 run だけを見る。backfill の重複判定は全件を見る。
    """
    records = []
    try:
        with open(metrics_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not include_test and rec.get("source") == "test":
                    continue
                records.append(rec)
    except FileNotFoundError:
        pass
    return records


def _sum_pass_metrics(dicts):
    """複数 run の _pass_metrics dict を合算する (per-repo 実行の pass2 集約)。"""
    if not dicts:
        return None
    total = {k: 0 for k in ("cost", "turns", "duration_s", "tokens_in", "tokens_out", "searches")}
    for d in dicts:
        for k in total:
            total[k] += d.get(k, 0)
    total["cost"] = round(total["cost"], 4)
    return total


def _total_cost(record):
    """record の pass1 / pass2 / clarity_pass から total_cost を合算する
    (live = metrics-append と rescue = metrics-backfill の共通定義)。"""
    return round(
        sum(
            p["cost"]
            for p in (record["pass1"], record["pass2"], record["clarity_pass"])
            if p and "cost" in p
        ),
        4,
    )


LINE_STATE_KEYS = (
    "article",
    "brief",
    "quiet",
    "hold",
    "mismatch",
    "suspect",
    "unverified",
)


def _sum_verification(verifies):
    """VERIFY 行群を合算する。行が無ければ None (呼2 が走らなかった日)。"""
    if not verifies:
        return None
    total = {k: sum(_nonneg_int(v.get(k)) for v in verifies) for k in VERIFY_KEYS}
    total["lines_verified"] = sum(1 for v in verifies if v.get("ran") is True)
    return total


# --- metrics-append <metrics_path> <date> <final_class> <report_count> <retry:0|1> ---
# stdin: 1 行 1 レコード、統一 framing "LABEL\t[meta\t]payload"。
#   RUN\t{json}          — claude -p result JSON。pass2 に合算 (ADR-0008 の写像)
#   LINT\t{json}         — report-lint (ctl-016) の JSON
#   CLARITY\t<ok:0|1>\t{json} — 呼2 (clarity + 原典照合) の発動記録 (ADR-0010/0017)
#   STATE\t<track>\t<token>[\t<token>...] — line の内容状態 (ADR-0017)。token は
#                        LINE_STATE_KEYS のいずれかで 1 つずつ加算 (article / brief /
#                        quiet / hold が本体、mismatch / suspect / unverified は重ね計上)
#   VERIFY\t{json}       — verify-read の出力。5 key を合算、lines_verified = ran の数
# ラベル不明・payload 破損の行は skip (収集は non-fatal)。
# pass1 は per-repo 化で廃止 (None 固定)。第 5 引数はリトライ発生の有無で、
# レコード互換のため旧フィールド名 fallback_used に記録する。
# clarity_pass (ADR-0010): verdict やスコアは保存しない (in-loop 型 — 消費は
# run 内で完結し、ここは発動事実のみ)。
def cmd_metrics_append(argv):
    from datetime import datetime

    if len(argv) < 5:
        print(
            "usage: metrics-append <metrics_path> <date> <final_class> "
            "<report_count> <retry:0|1> [source=live|test]",
            file=sys.stderr,
        )
        return 64
    metrics_path, date_s, final_class, report_count, retry = argv[:5]
    # source="test" は試験 seam の run。_load_metrics の既定で集計から除かれる
    source = argv[5] if len(argv) > 5 and argv[5] else "live"

    runs, lint, clarities = [], None, []
    line_states = {k: 0 for k in LINE_STATE_KEYS}
    verifies = []
    for line in sys.stdin.read().split("\n"):
        line = line.strip()
        if not line:
            continue
        label, _, payload = line.partition("\t")
        if label == "STATE":
            for token in payload.split("\t")[1:]:
                if token in line_states:
                    line_states[token] += 1
        elif label == "VERIFY":
            try:
                v = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if isinstance(v, dict):
                verifies.append(v)
        elif label == "CLARITY":
            ok, _, cj = payload.partition("\t")
            try:
                clarities.append(
                    {
                        "ran": True,
                        "ok": ok == "1",
                        **_pass_metrics(json.loads(cj)),
                    }
                )
            except (json.JSONDecodeError, AttributeError, TypeError):
                clarities.append({"ran": True, "ok": ok == "1"})
        elif label == "LINT":
            try:
                lint = json.loads(payload)
            except json.JSONDecodeError:
                continue
        elif label == "RUN":
            try:
                runs.append(_pass_metrics(json.loads(payload)))
            except json.JSONDecodeError:
                continue

    # clarity_pass: 1 本ならそのまま (旧来互換)。複数 (daily line 追加後の 1 日複数
    # line 実行) は合算して 1 dict に写像する — ok は全 line 成功のときだけ true。
    if not clarities:
        clarity = None
    elif len(clarities) == 1:
        clarity = clarities[0]
    else:
        metric_dicts = [{k: v for k, v in c.items() if k not in ("ran", "ok")} for c in clarities]
        summed = _sum_pass_metrics([m for m in metric_dicts if m])
        clarity = {
            "ran": True,
            "ok": all(c.get("ok") for c in clarities),
            **(summed or {}),
        }

    record = {
        "date": date_s,
        "ts": datetime.now().isoformat(timespec="seconds"),
        "source": source,
        "final_class": final_class,
        "report_count": int(report_count or 0),
        "fallback_used": retry == "1",
        "pass1": None,
        "pass2": _sum_pass_metrics(runs),
        "clarity_pass": clarity,
        "lint": lint,
        "line_states": line_states,
        "verification": _sum_verification(verifies),
    }
    record["total_cost"] = _total_cost(record)
    with open(metrics_path, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")
    print(f"metrics: appended {date_s} ({final_class}, {report_count} reports, {len(runs)} runs)")
    return 0


# Pass[12] = 旧 2-pass 形式 (〜2026-08)、Run(<track>) = per-repo 形式 (ADR-0008)、
# Clarity = 呼2 clarity 改稿 (ADR-0010)。per-repo の Run 行は pass2 に合算して
# 旧レコード形へ写像する。
_SUMMARY_RE = re.compile(
    r"\[([\d: -]+)\] SUMMARY (Pass[12]|Run\([\w-]+\)|Clarity): cost=\$([\d.]+) turns=(\d+) "
    r"duration=(\d+)s tokens_in=(\d+) tokens_out=(\d+)(?: searches=(\d+))?"
)


# --- metrics-backfill <metrics_path> <logs_dir>: 既存ログの SUMMARY 行から過去分を投入 ---
# ログは 30 日ローテーションで消えるため、残存分を JSONL へ救済するワンショット。
# 既存 metrics の (date, ts) と重複する run は skip する (再実行安全)。
def cmd_metrics_backfill(argv):
    import os

    if len(argv) < 2:
        print("usage: metrics-backfill <metrics_path> <logs_dir>", file=sys.stderr)
        return 64
    metrics_path, logs_dir = argv[:2]

    existing = {
        (r.get("date"), r.get("ts")) for r in _load_metrics(metrics_path, include_test=True)
    }
    appended = 0

    log_files = sorted(
        f for f in os.listdir(logs_dir) if re.fullmatch(r"\d{4}-\d{2}-\d{2}\.log", f)
    )
    with open(metrics_path, "a") as out:
        for name in log_files:
            date_s = name[:-4]
            runs = []
            run = None
            with open(os.path.join(logs_dir, name)) as f:
                for line in f:
                    if "=== Starting daily research ===" in line:
                        run = {
                            "date": date_s,
                            "ts": None,
                            "source": "backfill",
                            "final_class": None,
                            "report_count": 0,
                            "fallback_used": False,
                            "pass1": None,
                            "pass2": None,
                            "clarity_pass": None,
                            "lint": None,
                            # ADR-0017 の field はログから復元しない
                            "line_states": None,
                            "verification": None,
                        }
                        runs.append(run)
                        continue
                    if run is None:
                        continue
                    m = _SUMMARY_RE.search(line)
                    if m:
                        ts, label = m.group(1), m.group(2)
                        run["ts"] = ts.replace(" ", "T")
                        metrics = {
                            "cost": float(m.group(3)),
                            "turns": int(m.group(4)),
                            "duration_s": int(m.group(5)),
                            "tokens_in": int(m.group(6)),
                            "tokens_out": int(m.group(7)),
                            "searches": int(m.group(8) or 0),
                        }
                        if label.startswith("Run("):
                            # per-repo 形式 (ADR-0008): 全 Run を pass2 に合算
                            run["pass2"] = _sum_pass_metrics(
                                [run["pass2"], metrics] if run["pass2"] else [metrics]
                            )
                        elif label == "Clarity":
                            # ok はログの WARN 行から後追いで False にする (下記)
                            run["clarity_pass"] = {"ran": True, "ok": True, **metrics}
                        else:
                            run[label.lower()] = metrics
                        continue
                    if "WARN: clarity pass failed" in line:
                        # SUMMARY 行なし (出力ゼロの失敗 = 典型) でも発動事実は残す
                        if run.get("clarity_pass"):
                            run["clarity_pass"]["ok"] = False
                        else:
                            run["clarity_pass"] = {"ran": True, "ok": False}
                    elif "=== Fallback:" in line or "retrying once" in line:
                        # 旧 2-pass 形式は "=== Fallback:"、per-repo 形式 (ADR-0008〜) は
                        # "WARN: Line X failed ... — retrying once" がリトライの痕跡
                        run["fallback_used"] = True
                    elif "Report existence gate passed:" in line:
                        cm = re.search(r"gate passed: (\d+) report", line)
                        if cm:
                            run["report_count"] = int(cm.group(1))
                    elif "=== Completed successfully ===" in line:
                        run["final_class"] = "OK"
                    elif "=== Failed (" in line:
                        fm = re.search(r"=== Failed \((\S+?),", line)
                        run["final_class"] = fm.group(1) if fm else "FAIL"

            for run in runs:
                if run["pass1"] is None and run["pass2"] is None:
                    continue  # SUMMARY 行のない中断 run はデータなし
                run["total_cost"] = _total_cost(run)
                if (run["date"], run["ts"]) in existing:
                    continue
                out.write(json.dumps(run, ensure_ascii=False) + "\n")
                appended += 1
    print(f"metrics: backfilled {appended} run(s) from {len(log_files)} log file(s)")
    return 0


def _frontmatter_kind(text):
    """先頭 YAML frontmatter の kind: を返す (無ければ article)。"""
    m = re.match(r"---\n(.*?)\n---", text, re.DOTALL)
    if m:
        k = re.search(r"^kind:\s*[\"']?([A-Za-z_-]+)", m.group(1), re.MULTILINE)
        if k:
            return k.group(1)
    return "article"


# --- report-lint <report_dir> <date> [config_path] ---
# 当日レポートの決定論的品質検査 (ctl-016)。stdout に JSON 1 行。
# exit 0 = 全 PASS または soft violation のみ / 2 = hard fail あり。
# hard: ソース節不在・出典 URL 0 件 (レポートの体を成していない)
# soft: 出典 < min_sources / 必須節欠落 / 本文長不足
# kind (ADR-0017): frontmatter の kind: を読む (無ければ article)。brief (短報) は
# 必須節 (機会メモ) と本文長の soft を免除し、hard と出典数 soft は article と同じ。
# 必須節は自由形式レポート (ADR-0009) の機械検査対象 — 機会メモのみ
# (ソース節は hard 判定として別途検査)。本文の記述規律は人間 consumer が判断する。
def cmd_report_lint(argv):
    import os

    if len(argv) < 2:
        print(
            "usage: report-lint <report_dir> <date> [config_path]",
            file=sys.stderr,
        )
        return 64
    report_dir, date_s = argv[:2]
    config_path = argv[2] if len(argv) >= 3 else "config.toml"

    min_sources = 5
    try:
        tomllib = _tomllib()
        with open(config_path, "rb") as f:
            min_sources = int(tomllib.load(f).get("report", {}).get("min_sources", min_sources))
    except (FileNotFoundError, ValueError, OSError):
        pass
    MIN_BODY_CHARS = 1500
    ARTICLE_SECTIONS = [
        "機会メモ",
    ]

    results = []
    try:
        files = sorted(
            f for f in os.listdir(report_dir) if f.startswith(f"{date_s}_") and f.endswith(".md")
        )
    except FileNotFoundError:
        files = []

    for name in files:
        hard, soft = [], []
        try:
            with open(os.path.join(report_dir, name)) as f:
                text = f.read()
        except OSError as e:
            results.append({"file": name, "hard": [f"read error: {e}"], "soft": []})
            continue

        kind = _frontmatter_kind(text)
        urls = re.findall(r"\[[^\]]*\]\((https?://[^)]+)\)", text)
        n_sources = len(set(urls))
        if "## ソース" not in text:
            hard.append("ソース節がない")
        if n_sources == 0:
            hard.append("出典 URL が 0 件")
        elif n_sources < min_sources:
            soft.append(f"出典 URL {n_sources} 件 (< {min_sources})")

        if kind != "brief":
            missing = [s for s in ARTICLE_SECTIONS if f"## {s}" not in text]
            if missing:
                soft.append(f"必須節欠落: {', '.join(missing)}")

            if len(text) < MIN_BODY_CHARS:
                soft.append(f"本文 {len(text)} 字 (< {MIN_BODY_CHARS})")

        results.append(
            {
                "file": name,
                "kind": kind,
                "hard": hard,
                "soft": soft,
                "body_chars": len(text),
            }
        )

    n_hard = sum(1 for r in results if r["hard"])
    n_soft = sum(1 for r in results if r["soft"])
    print(
        json.dumps(
            {
                "date": date_s,
                "files": len(results),
                "hard_fail": n_hard,
                "soft_fail": n_soft,
                "results": results,
            },
            ensure_ascii=False,
        )
    )
    return 2 if n_hard else 0


# --- wiki-quality-scan <vault_path> [days]: wiki 品質注記のレポート逆引き集計 ---
# ingest 時に wiki/concept/*.md へ残る「FLAGGED」「一次未照合」注記を、
# 同じ行ブロック内の [[<report-stem>]] リンクでレポート・line に逆引きする。
# ingest 率は 98% で判別力がないため、品質信号はこの注記密度を使う (ADR-0006)。
def cmd_wiki_quality_scan(argv):
    import os
    from collections import defaultdict
    from datetime import date, timedelta

    if len(argv) < 1:
        print(
            "usage: wiki-quality-scan <vault_path> [days] [config_path]",
            file=sys.stderr,
        )
        return 64
    vault_path = argv[0]
    days = int(argv[1]) if len(argv) >= 2 else 90
    config_path = argv[2] if len(argv) >= 3 else "config.toml"
    cutoff = (date.today() - timedelta(days=days)).isoformat()

    # line 逆引き用の既知 track 名 (現行 + aliases)。track 名はアンダースコアを
    # 含みうる (agent_systems) ため、既知名の最長一致で切る。config が読めない
    # 場合は「最初にハイフンを含むトークンの手前まで」の heuristic に落とす。
    known_tracks = []
    try:
        _, tracks = _load_tracks(config_path)
        for name, v in tracks.items():
            known_tracks.append(name)
            known_tracks.extend(v.get("aliases", []))
        known_tracks.sort(key=len, reverse=True)
    except (FileNotFoundError, ValueError):
        pass

    def line_of_stem(stem):
        rest = stem[11:]  # "YYYY-MM-DD_" を除去
        for k in known_tracks:
            if rest == k or rest.startswith(k + "_"):
                return k
        head = []
        for t in rest.split("_"):
            if "-" in t:
                break
            head.append(t)
        return "_".join(head) if head else rest

    concept_dir = os.path.join(vault_path, "wiki", "concept")
    link_re = re.compile(r"\[\[(\d{4}-\d{2}-\d{2}_[a-z_]+_[A-Za-z0-9-]+)")
    flag_re = re.compile(r"FLAGGED|一次未照合|推定として扱う")

    flagged = defaultdict(list)  # report_stem -> [concept_page, ...]
    try:
        pages = sorted(f for f in os.listdir(concept_dir) if f.endswith(".md"))
    except FileNotFoundError:
        print(f"wiki concept dir not found: {concept_dir}", file=sys.stderr)
        return 1

    for page in pages:
        try:
            with open(os.path.join(concept_dir, page)) as f:
                text = f.read()
        except OSError:
            continue
        # 段落 (空行区切り) 単位で注記とリンクを対応づける
        for block in text.split("\n\n"):
            if not flag_re.search(block):
                continue
            for stem in link_re.findall(block):
                if stem[:10] >= cutoff:
                    flagged[stem].append(page[:-3])

    by_line = defaultdict(int)
    for stem in flagged:
        by_line[line_of_stem(stem)] += 1

    print(
        json.dumps(
            {
                "days": days,
                "flagged_reports": len(flagged),
                "by_line": dict(sorted(by_line.items())),
                "reports": {stem: sorted(set(pages)) for stem, pages in sorted(flagged.items())},
            },
            ensure_ascii=False,
        )
    )
    return 0


# --- review-age <state_path>: 前回 /dr-review からの経過日数を出力 ---
# state ファイル (.notes/dr-review-state.json) が無ければ "never" を出力する。
def cmd_review_age(argv):
    from datetime import date

    if len(argv) < 1:
        print("usage: review-age <state_path>", file=sys.stderr)
        return 64
    try:
        with open(argv[0]) as f:
            last = json.load(f).get("last_review", "")
        d = date.fromisoformat(last[:10])
        print((date.today() - d).days)
    except (FileNotFoundError, json.JSONDecodeError, ValueError):
        print("never")
    return 0


# --- expect-check <metrics_path>: DR-Expect trailer を metrics 実測と突合 ---
# stdin 1 行 1 expect: "<commit_date>\t<metric> <op> <value>"。
# commit_date より後の record 群で metric を評価し、verdict を 1 行ずつ出力。
# metric 語彙: {pass1|pass2}_turns_{p50|p90|max} / {pass1|pass2}_cost_{mean|max} /
#   total_cost_{mean|max} / fallback_rate / report_count_min / no_report_count /
#   lint_hard_count / quiet_rate / receipt_count_min / unsupported_rate /
#   unverifiable_rate / clarity_ok_rate (ADR-0017。line_states / verification /
#   clarity_pass が None の record は分母から除く)
def cmd_expect_check(argv):
    if len(argv) < 1:
        print("usage: expect-check <metrics_path>  (expects on stdin)", file=sys.stderr)
        return 64
    records = _load_metrics(argv[0])

    def percentile(vals, p):
        vals = sorted(vals)
        if not vals:
            return None
        i = min(len(vals) - 1, max(0, round(p / 100 * (len(vals) - 1))))
        return vals[i]

    def metric_value(name, recs):
        m = re.fullmatch(r"(pass1|pass2)_turns_(p50|p90|max)", name)
        if m:
            vals = [r[m.group(1)]["turns"] for r in recs if r.get(m.group(1))]
            if not vals:
                return None
            return max(vals) if m.group(2) == "max" else percentile(vals, int(m.group(2)[1:]))
        m = re.fullmatch(r"(pass1|pass2|total)_cost_(mean|max)", name)
        if m:
            key = m.group(1)
            vals = [
                (r.get("total_cost") if key == "total" else (r.get(key) or {}).get("cost"))
                for r in recs
            ]
            vals = [v for v in vals if v is not None]
            if not vals:
                return None
            return max(vals) if m.group(2) == "max" else sum(vals) / len(vals)
        if name == "fallback_rate":
            return sum(1 for r in recs if r.get("fallback_used")) / len(recs) if recs else None
        if name == "report_count_min":
            vals = [r.get("report_count", 0) for r in recs]
            return min(vals) if vals else None
        if name == "no_report_count":
            return sum(1 for r in recs if r.get("final_class") == "E_NO_REPORT")
        if name == "lint_hard_count":
            return sum((r.get("lint") or {}).get("hard_fail", 0) for r in recs)
        states = [r["line_states"] for r in recs if isinstance(r.get("line_states"), dict)]
        if name == "quiet_rate":
            quiet = sum(s.get("quiet", 0) + s.get("hold", 0) for s in states)
            total = sum(receipts(s) for s in states)
            return quiet / total if total else None
        if name == "receipt_count_min":
            return min(receipts(s) for s in states) if states else None
        verif = [r["verification"] for r in recs if isinstance(r.get("verification"), dict)]
        if name in ("unsupported_rate", "unverifiable_rate"):
            sup = sum(v.get("supported", 0) for v in verif)
            par = sum(v.get("partial", 0) for v in verif)
            uns = sum(v.get("unsupported", 0) for v in verif)
            unv = sum(v.get("unverifiable", 0) for v in verif)
            if name == "unsupported_rate":
                # 取得失敗 (unverifiable) は分母に入れない — 照合できた claim 中の不一致率
                denom = sup + par + uns
                return (uns + par) / denom if denom else None
            denom = sup + par + uns + unv
            return unv / denom if denom else None
        if name == "clarity_ok_rate":
            cps = [r["clarity_pass"] for r in recs if isinstance(r.get("clarity_pass"), dict)]
            return sum(1 for c in cps if c.get("ok")) / len(cps) if cps else None
        return None

    def receipts(s):
        return sum(s.get(k, 0) for k in ("article", "brief", "quiet", "hold"))

    OPS = {
        "<=": lambda a, b: a <= b,
        ">=": lambda a, b: a >= b,
        "<": lambda a, b: a < b,
        ">": lambda a, b: a > b,
        "==": lambda a, b: a == b,
    }
    expect_re = re.compile(r"(\S+)\s*(<=|>=|==|<|>)\s*([\d.]+)")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        commit_date, _, expr = line.partition("\t")
        m = expect_re.fullmatch(expr.strip())
        if not m:
            print(f"INVALID\t{expr}\t(書式不正)")
            continue
        name, op, target = m.group(1), m.group(2), float(m.group(3))
        recs = [r for r in records if r.get("date", "") > commit_date]
        val = metric_value(name, recs)
        if val is None:
            print(f"INSUFFICIENT_DATA\t{expr}\t(n={len(recs)})")
        else:
            verdict = "ACHIEVED" if OPS[op](val, target) else "NOT_ACHIEVED"
            shown = round(val, 4) if isinstance(val, float) else val
            print(f"{verdict}\t{expr}\t(実測 {shown}, n={len(recs)})")
    return 0


# === API 課金 (Claude API の key で claude -p を回す) ===========================
#
# [billing] の契約:
#   mode            "api" | "subscription" (既定 subscription = Max plan の OAuth)
#   env_file        ANTHROPIC_API_KEY を持つ env ファイル (repo の外。~ 展開あり)
#   monthly_cap_usd 月の API 支出上限。超えそうなら残りの line を止める
#   daily_cap_usd   1 日の API 支出上限 (暴走の止め)
#   call1_max_usd   呼1 1 回の --max-budget-usd
#   call2_max_usd   呼2 1 回の --max-budget-usd
# 支出の正本は state/api-spend.jsonl (1 呼び出し 1 行、claude が報告する total_cost_usd)。
# invariant: line を始めるのは「月・日の残額 >= call1_max + call2_max」のときだけ —
# --max-budget-usd が各呼び出しを抑えるので、上限の超過は最後の 1 turn 分に収まる。
BILLING_MODES = ("api", "subscription")
_BILLING_DEFAULTS = {
    "mode": "subscription",
    "env_file": "~/.config/daily-research/env",
    "monthly_cap_usd": 190.0,
    "daily_cap_usd": 15.0,
    "call1_max_usd": 4.0,
    "call2_max_usd": 1.5,
}


def _billing(cfg):
    import os

    b = dict(_BILLING_DEFAULTS)
    raw = cfg.get("billing", {})
    if not isinstance(raw, dict):
        raise ValueError("[billing] must be a table")
    for k, v in raw.items():
        if k not in b:
            raise ValueError(f"[billing].{k} is not a known key ({', '.join(b)})")
        b[k] = v
    if b["mode"] not in BILLING_MODES:
        raise ValueError(f"[billing].mode must be one of {BILLING_MODES}, got {b['mode']!r}")
    if not isinstance(b["env_file"], str) or not b["env_file"]:
        raise ValueError("[billing].env_file must be a non-empty string")
    for k in ("monthly_cap_usd", "daily_cap_usd", "call1_max_usd", "call2_max_usd"):
        v = b[k]
        if isinstance(v, bool) or not isinstance(v, (int, float)) or v <= 0:
            raise ValueError(f"[billing].{k} must be a number > 0, got {v!r}")
        b[k] = float(v)
    reserve = b["call1_max_usd"] + b["call2_max_usd"]
    if reserve > b["daily_cap_usd"] or b["daily_cap_usd"] > b["monthly_cap_usd"]:
        raise ValueError(
            "[billing] needs call1_max_usd + call2_max_usd <= daily_cap_usd <= monthly_cap_usd"
        )
    b["env_file"] = os.path.expanduser(b["env_file"])
    return b


# --- billing-config <config_path>: [billing] を検証して 1 行 TSV で出力 ---
# mode \t env_file \t monthly_cap \t daily_cap \t call1_max \t call2_max。不正は rc 2。
def cmd_billing_config(argv):
    if not argv:
        print("usage: billing-config <config_path>", file=sys.stderr)
        return 64
    try:
        tomllib = _tomllib()
        with open(argv[0], "rb") as f:
            b = _billing(tomllib.load(f))
    except (OSError, ValueError) as e:
        print(f"billing-config: {e}", file=sys.stderr)
        return 2
    print(
        "\t".join(
            [b["mode"], b["env_file"]]
            + [
                f"{b[k]:g}"
                for k in ("monthly_cap_usd", "daily_cap_usd", "call1_max_usd", "call2_max_usd")
            ]
        )
    )
    return 0


# --- env-key <env_file>: env ファイルの ANTHROPIC_API_KEY の値を出力 ---
# KEY=VALUE / export KEY=VALUE、前後の引用符を外す。無い・空・読めないは rc 1 (値は出さない)。
# 呼ぶ側は出力を変数に取るだけで、ログにもエラー文にも値を載せない。
def cmd_env_key(argv):
    if not argv:
        print("usage: env-key <env_file>", file=sys.stderr)
        return 64
    try:
        with open(argv[0], encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        print(f"env-key: cannot read {argv[0]}", file=sys.stderr)
        return 1
    value = ""
    for line in lines:
        m = re.match(r"\s*(?:export\s+)?ANTHROPIC_API_KEY\s*=\s*(.*?)\s*$", line)
        if m:
            value = m.group(1)
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
    if not value:
        print(f"env-key: ANTHROPIC_API_KEY is missing or empty in {argv[0]}", file=sys.stderr)
        return 1
    print(value)
    return 0


def _spend_totals(ledger, date_s):
    """(month_total, day_total, skipped_lines)。読めない行は数えて返す — 黙って捨てると
    その費用が累計から消え、上限の判定が甘くなる。台帳が無いのは 0 円 (初回)。"""
    month, day, skipped = 0.0, 0.0, 0
    try:
        with open(ledger, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return month, day, skipped
    for line in lines:
        if not line.strip():
            continue
        try:
            r = json.loads(line)
            d = str(r.get("date", ""))
            c = float(r.get("cost_usd", 0) or 0)
        except (ValueError, TypeError, AttributeError):
            skipped += 1
            continue
        if d[:7] == date_s[:7]:
            month += c
            if d == date_s:
                day += c
    return month, day, skipped


# --- spend-add <ledger> <date> <line> <call> [fallback_usd]: stdin の claude JSON の費用を台帳に追記 ---
# JSON に total_cost_usd が無い (timeout で kill された・解析失敗) ときは、その呼び出しが使えた
# 上限額 fallback_usd を "estimated": true 付きで記録する — 0 円にすると、使ったかもしれない額が
# 累計から消えて上限の判定が甘くなる。追記した費用を出力。書けなければ rc 1。
def cmd_spend_add(argv):
    import datetime
    import os

    if len(argv) < 4:
        print("usage: spend-add <ledger> <date> <line> <call> [fallback_usd]", file=sys.stderr)
        return 64
    ledger, date_s, line, call = argv[:4]
    fallback = float(argv[4]) if len(argv) >= 5 else 0.0
    cost, estimated = None, False
    try:
        d = _result_dict(json.loads(sys.stdin.read() or "null")) or {}
        if d.get("total_cost_usd") is not None:
            cost = float(d["total_cost_usd"])
    except (ValueError, TypeError, AttributeError):
        cost = None
    if cost is None:
        cost, estimated = fallback, True
    rec = {
        "ts": datetime.datetime.now().isoformat(timespec="seconds"),
        "date": date_s,
        "line": line,
        "call": call,
        "cost_usd": round(cost, 4),
    }
    if estimated:
        rec["estimated"] = True
    os.makedirs(os.path.dirname(ledger) or ".", exist_ok=True)
    fd = os.open(ledger, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(f"{cost:.4f}")
    return 0


# --- spend-gate <ledger> <date> <monthly_cap> <daily_cap> <reserve> ---
# 次の line を始めてよいか。"ok|stop \t month_total \t day_total" を出力し、stop は rc 1。
# 台帳が読めない・読めない行がある場合は rc 2 (上限を判定できない — 呼ぶ側は止める)。
def cmd_spend_gate(argv):
    if len(argv) < 5:
        print(
            "usage: spend-gate <ledger> <date> <monthly_cap> <daily_cap> <reserve>", file=sys.stderr
        )
        return 64
    ledger, date_s = argv[:2]
    monthly, daily, reserve = (float(x) for x in argv[2:5])
    try:
        month, day, skipped = _spend_totals(ledger, date_s)
    except OSError as e:
        print(f"spend-gate: cannot read {ledger}: {e}", file=sys.stderr)
        return 2
    if skipped:
        # 読めない行の費用は分からない。数えられない支出があるまま上限を判定しない
        print(f"spend-gate: {skipped} unreadable line(s) in {ledger}", file=sys.stderr)
        return 2
    ok = monthly - month >= reserve and daily - day >= reserve
    print(f"{'ok' if ok else 'stop'}\t{month:.2f}\t{day:.2f}")
    return 0 if ok else 1


COMMANDS = {
    "error-fields": cmd_error_fields,
    "log-summary": cmd_log_summary,
    "vault-path": cmd_vault_path,
    "report-dir": cmd_report_dir,
    "template-path": cmd_template_path,
    "tracks": cmd_tracks,
    "rotation-pick": cmd_rotation_pick,
    "past-themes": cmd_past_themes,
    "past-topics-append": cmd_past_topics_append,
    "line-brief": cmd_line_brief,
    "receipt-read": cmd_receipt_read,
    "verify-read": cmd_verify_read,
    "config-get": cmd_config_get,
    "searches": cmd_searches,
    "metrics-append": cmd_metrics_append,
    "metrics-backfill": cmd_metrics_backfill,
    "report-lint": cmd_report_lint,
    "wiki-quality-scan": cmd_wiki_quality_scan,
    "review-age": cmd_review_age,
    "expect-check": cmd_expect_check,
    "billing-config": cmd_billing_config,
    "env-key": cmd_env_key,
    "spend-add": cmd_spend_add,
    "spend-gate": cmd_spend_gate,
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        print(f"usage: dr_pipeline.py <{' | '.join(COMMANDS)}> [args]", file=sys.stderr)
        return 64
    return COMMANDS[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
