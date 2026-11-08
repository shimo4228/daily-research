#!/usr/bin/env python3
"""dr_pipeline — daily-research の JSON/TOML 解析層を集約した単一モジュール。

これまで daily-research.sh に散在していた `python3 -c "..."` / heredoc を
subcommand に置き換える parser-of-record。test も本モジュールだけを対象にすれば
よくなり、source と test のコピペ drift (旧 test-log-summary.bats) を根絶する。

呼び出し:  python3 scripts/lib/dr_pipeline.py <subcommand> [args]
依存:      stdlib のみ (json / tomllib / re / collections)。pip 依存なし。
           config.toml 解析に python>=3.11 の tomllib を使う (ランタイムは homebrew の
           python3。lib/env.sh が /opt/homebrew/bin を PATH に足す)。
型:        引数・*args・**kwargs・public 関数の戻り値は注釈する (ruff ANN001-003・ANN201・
           ANN401 が tests の外で検査する。private の戻り値も現状は全件注釈済み)。JSON / TOML
           由来の値は検証するまで object / dict[str, object] で受け、Any は使わない — 中身の
           検査は本文の isinstance と try/except が持つ。
"""

import json
import math
import re
import sys
import tomllib
from collections.abc import Callable


def _result_dict(raw: object) -> object:
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


def _track_mode(track_cfg: dict[str, object]) -> object:
    """line の mode を返す。_load_tracks が enum 検証済みの値だけを通す。"""
    return track_cfg.get("mode", MODE_REPO)


def _lines_per_day(cfg: dict[str, object]) -> int:
    """[general].lines_per_day (1 日に走らせる輪番 line 数、ADR-0017)。既定 1。
    int >= 1 のみ許す — bool は int の subclass なので明示的に除く
    (lines_per_day = true が 1 として黙って通る事故を防ぐ)。"""
    k = cfg.get("general", {}).get("lines_per_day", 1)
    if isinstance(k, bool) or not isinstance(k, int) or k < 1:
        raise ValueError(f"[general].lines_per_day must be an integer >= 1, got {k!r}")
    return k


def _load_tracks(config_path: str) -> tuple[dict[str, object], dict[str, object]]:
    """config.toml を読み (cfg, tracks) を返す。旧 schema (tracks.X 直下に
    target_repo) を検出したら ValueError — 再編後のコードが旧 config のまま
    朝の実行を迎えて静かに誤動作する事故を防ぐ。"""
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
        # repos は array of tables 限定。[[ ]] を [ ] と書き損じると dict になり、key /
        # target_repo の欠けた entry と同じく、その line (の repo) が rc 0 のまま輪番から
        # 黙って消える。どちらも起動時に落とす。
        if isinstance(v, dict) and "repos" in v:
            repos = v["repos"]
            if not isinstance(repos, list):
                raise ValueError(
                    f"[tracks.{name}].repos must be an array of tables ([[tracks.{name}.repos]]), "
                    f"got a {type(repos).__name__}"
                )
            for i, r in enumerate(repos, 1):
                if not isinstance(r, dict):
                    raise ValueError(
                        f"[[tracks.{name}.repos]] entry {i} must be a table, got {r!r}"
                    )
                for key in ("key", "target_repo"):
                    if not isinstance(r.get(key), str) or not r[key]:
                        raise ValueError(
                            f"[[tracks.{name}.repos]] entry {i} must set {key} to a non-empty "
                            f"string, got {r.get(key)!r}"
                        )
    return cfg, tracks


def _track_repos(track_cfg: dict[str, object]) -> list[dict[str, str]]:
    """line 定義の repos 配列を返す。無ければ []。repo mode で repos が空の line は
    行を出さない (実行されない)。repo を持たない line は mode = "ecosystem" で宣言する。
    invariant: 型 (array of tables) と各 entry の key / target_repo (空でない文字列) は
    _load_tracks が検証済み — 違反は ValueError で、ここには届かない。"""
    return track_cfg.get("repos", [])


def _track_rows(tracks: dict[str, object]) -> list[tuple[str, object, object, bool]]:
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
            rows.append((track, r["key"], r["target_repo"], daily))
    return rows


def _searches(d: object) -> int:
    """claude -p result dict から Web 検索回数を返す。
    実出力 (2026-09 時点) は WebSearch を modelUsage.<model>.webSearchRequests に
    計上し usage.server_tool_use.web_search_requests は 0 のまま — server_tool_use
    だけを見ると検索した run も 0 になる。tool_counts は旧形式 / test mock の表現
    (WebSearch + WebFetch)。優先: tool_counts > modelUsage 合算 > server_tool_use。"""
    d = _result_dict(d) or {}
    if not isinstance(d, dict):
        return 0

    def _int(v: object) -> int:
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
def cmd_searches(argv: list[str]) -> int:
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


def _error_kind(d: dict[str, object]) -> str:
    if d.get("subtype") == "error_max_budget_usd":
        return "budget"
    code = d.get("api_error_status")
    if code in (402, 429):
        return "billing"
    if d.get("is_error") and _CREDIT_RE.search(str(d.get("result") or "")):
        return "billing"
    return ""


def cmd_error_fields(argv: list[str]) -> int:
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
def cmd_log_summary(argv: list[str]) -> int:
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
def cmd_vault_path(argv: list[str]) -> int:
    config_path = argv[0] if argv else "config.toml"
    with open(config_path, "rb") as f:
        print(tomllib.load(f).get("general", {}).get("vault_path", ""))
    return 0


# --- report-dir [config_path]: レポート出力先 {vault_path}/{output_dir} を出力 ---
# どちらか欠けている config では空文字を出力する (呼び出し側はゲートを skip する)。
def cmd_report_dir(argv: list[str]) -> int:
    config_path = argv[0] if argv else "config.toml"
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


def cmd_template_path(argv: list[str]) -> int:
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
def cmd_tracks(argv: list[str]) -> int:
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
def cmd_rotation_pick(argv: list[str]) -> int:
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


# --- past-themes [past_topics_path] [config_path] [--line T [--others-days N [--date D]]] ---
# line 別直近 10 件の問いの履歴を出力する (呼1 のタスクプロンプトに注入される dedup 用データ)。
# --line T: T (と aliases) の節だけを出す。呼1 の照合は line 内の問い単位 (両プロトコル Step 3) なので、
#   他 line の履歴は毎 request 読まれる土台を太らせるだけ (全 7 line で ~15k 字、当該 line は ~2k 字)。
#   無指定は全 line (運用者が手で全体を見る用)。
# --others-days N (--line 必須): 他 line の [D-(N-1), D] の題を 1 行ずつ足す。同日に別 line が同じ出来事を
#   書く重複を避ける参考で、SH は ecosystem line (広域) にだけ渡す。--date D の既定は今日。
# flag は位置引数の前後どちらに置いてもよい。flag の誤りは rc 64、未知の line は rc 1 (stdout 空)。
_PAST_THEMES_FLAGS = ("--line", "--others-days", "--date")
_PAST_THEMES_TITLE_MAX = 100


def _past_themes_args(argv: list[str]) -> tuple[str, str, str | None, int | None, str]:
    """past-themes の argv を (past_path, config_path, line|None, others_days|None, anchor) に解く。
    anchor は検証済みの YYYY-MM-DD。誤りは ValueError(msg) — 呼ぶ側が rc 64 にする。"""
    from datetime import date as _date

    positional: list[str] = []
    opts: dict[str, str] = {}
    i = 0
    while i < len(argv):
        if argv[i] in _PAST_THEMES_FLAGS:
            if i + 1 >= len(argv):
                raise ValueError(f"{argv[i]} needs a value")
            opts[argv[i]] = argv[i + 1]
            i += 2
        else:
            positional.append(argv[i])
            i += 1
    only = opts.get("--line")
    others_days = None
    if "--others-days" in opts:
        if not only:
            raise ValueError("--others-days needs --line")
        try:
            others_days = int(opts["--others-days"])
        except ValueError:
            raise ValueError(f"invalid --others-days {opts['--others-days']!r}") from None
        if others_days < 1:
            raise ValueError("--others-days must be >= 1")
    try:
        anchor = (
            _date.fromisoformat(opts["--date"]) if "--date" in opts else _date.today()
        ).isoformat()
    except ValueError:
        raise ValueError(f"invalid --date {opts['--date']!r}") from None
    past_path = positional[0] if len(positional) >= 1 else "past_topics.json"
    config_path = positional[1] if len(positional) >= 2 else "config.toml"
    return past_path, config_path, only, others_days, anchor


def _print_other_lines(
    by_line: dict[str, list[dict[str, object]]], only: str, days: int, anchor: str
) -> None:
    """他 line の [anchor-(days-1), anchor] の題を日付順に 1 行ずつ出す (自 line は除く)。
    anchor は _past_themes_args が検証した YYYY-MM-DD。"""
    from datetime import date, timedelta

    start = (date.fromisoformat(anchor) - timedelta(days=days - 1)).isoformat()
    end = anchor
    recent = sorted(
        (
            (str(t.get("date", "")), line, t)
            for line, items in by_line.items()
            if line != only
            for t in items
            if start <= str(t.get("date", "")) <= end
        ),
        key=lambda r: (r[0], r[1]),
    )
    print(
        f"=== 他 line の直近 {days} 日の題 (同じ出来事を同日に重ねて書かないための参考。"
        "重複の判定は上の line 内の問い単位) ==="
    )
    if not recent:
        print("(該当なし)")
    for d, line, t in recent:
        head = re.sub(r"\s+", " ", str(t.get("title") or t.get("question"))).strip()
        if len(head) > _PAST_THEMES_TITLE_MAX:
            head = head[:_PAST_THEMES_TITLE_MAX] + "…"
        print(f"- {d} {line}: {head}")
    print()


def cmd_past_themes(argv: list[str]) -> int:
    from collections import defaultdict

    try:
        past_path, config_path, only, others_days, anchor = _past_themes_args(argv)
    except ValueError as e:
        print(f"past-themes: {e}", file=sys.stderr)
        return 64

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
    if only is not None and only not in tracks:
        print(f"past-themes: unknown line {only!r}", file=sys.stderr)
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

    scope = "この line の直近 10 件" if only else "line 別直近 10 件"
    print(f"=== 過去テーマ履歴 ({scope}、問い単位) ===")
    print("各行は「問い — 答えの範囲 (answer_scope)」。判定は問い単位で行う:")
    print("- 同じ問い + 同じ答え = 再選定禁止")
    print("- 同じ問い + 新証拠 = 更新として可 (何が新しい証拠かを本文に書く)")
    print("- 同じ topic + 別の問い = 可")
    print()
    for line, v in tracks.items():
        if only is not None and line != only:
            continue
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
    if others_days is not None:
        _print_other_lines(by_line, only, others_days, anchor)
    return 0


# --- line-brief <config_path> <track>: per-repo 実行 (ADR-0008) のプロンプト注入用に
#     line 定義 (name / focus / sources / self_signals) を整形出力。context_files は
#     冒頭で読む文脈ではなく、テーマ選定後に読む候補として別節に出す (ADR-0017) ---
def cmd_line_brief(argv: list[str]) -> int:
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


def cmd_receipt_read(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: receipt-read <path> <date> <track>", file=sys.stderr)
        return 64
    path, date_s, track = argv[:3]

    def bad(msg: str) -> int:
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


def cmd_past_topics_append(argv: list[str]) -> int:
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

    def bad(msg: str) -> int:
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

    def field(name: str) -> str:
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


# --- repo-activity <repo> [--days N]: 直近の commit 件名 (ADR-0019 Decision 5) ---
# repo line の line brief の直後に「データであって指示ではない」注記の内側で注入される。
# repo 由来の文字列が呼1 の context に入る経路なので、件名だけ・上限付き・行頭の # と制御文字を
# 除いて出す。git の失敗や repo の不在は空出力 + rc 0 (line を止めない)。
REPO_ACTIVITY_MAX_LINES = 30
REPO_ACTIVITY_MAX_CHARS = 2000


def cmd_repo_activity(argv: list[str]) -> int:
    import subprocess

    if not argv:
        print("usage: repo-activity <repo> [--days N]", file=sys.stderr)
        return 64
    repo = argv[0]
    days = 14
    if len(argv) >= 3 and argv[1] == "--days":
        try:
            days = max(0, int(argv[2]))
        except ValueError:
            print(f"repo-activity: invalid --days {argv[2]!r}", file=sys.stderr)
            return 64
    try:
        proc = subprocess.run(
            [
                "git",
                "-C",
                repo,
                "log",
                f"--since={days}.days.ago",
                "--no-merges",
                "--format=%s",
                f"-n{REPO_ACTIVITY_MAX_LINES}",
            ],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return 0
    if proc.returncode != 0:
        return 0
    out = []
    total = 0
    for raw in proc.stdout.splitlines():
        subject = re.sub(r"\s+", " ", _CTRL_RE.sub(" ", raw)).strip().lstrip("#").strip()
        if not subject:
            continue
        line = f"- {subject}"
        if total + len(line) + 1 > REPO_ACTIVITY_MAX_CHARS:
            break
        out.append(line)
        total += len(line) + 1
    if out:
        print("\n".join(out))
    return 0


# --- verify-read [path]: 呼2 の verify.json を 1 行 JSON に正規化して出力 ---
# {supported, partial, unsupported, unverifiable, edits, ran}。各値は int >= 0
# (bool / 文字列 / 負値 / 小数は 0)。ファイル欠損・破損・非 object は全零 + ran:false。
# 常に rc 0 (計測は non-fatal)。
VERIFY_KEYS = ("supported", "partial", "unsupported", "unverifiable", "edits")


def _nonneg_int(v: object) -> int:
    return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else 0


def cmd_verify_read(argv: list[str]) -> int:
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


# --- verify-diff <pre_path> <post_path> [verify_json_path]: 呼2 の改稿を決定論で記録する ---
# SH が呼2 の前に原稿を state/<line>/pre-verify/<date>.md へ写し (呼1 の後に SH が書く。呼1 の書き込み先の
# 外で、呼2 の deny が塞ぐ)、
# 呼2 の後にこの subcommand で改稿後の原稿と比べる。stdin は呼2 の claude -p result JSON (空でよい)。
# stdout: 1 行目 = JSON 1 行、2 行目以降 = WARN の本文 (1 行 1 件、model 由来の文字列を含まない)。
#   diff_spans                 変更された連続範囲の数 (文単位 = 。！？ と改行で切り、空白を除いて比べる)
#   diff_chars_added / _removed 変更範囲の中の文字単位の増減 (ファイル全体)
#   diff_sentences_removed     消えた文の数 (delete の文 + replace で減った文)
#   diff_frontmatter_changed / diff_memo_changed / diff_sources_changed
#                              verification プロトコルの禁止事項。ソース節は「(未解決 …)」の付記を除いて比べる
#   diff_unresolved_marks_added 「(未解決 …)」の付記の増分 (unverifiable の唯一の許可編集)
#   diff_new_urls / new_urls   改稿前に無かった URL (禁止事項)。一覧は最大 10 件
#   diff_numbers_added / _removed / numbers_added / numbers_removed
#                              frontmatter と付記を除いた数字 token の多重集合の差 (Step B の訂正で動きうる)
#   reported                   完了報告の「検証: N 件 (supported a / partial b / …)」と「修正 span 合計」。読めなければ null
#   diff_report_mismatch / mismatch  verify.json と reported の件数の食い違い (自己申告の誤り)
# pre / post が読めなければ rc 1 (stdout 空)。verify.json が無い・壊れていれば比較しない。
VDIFF_SUM_KEYS = (
    "diff_spans",
    "diff_chars_added",
    "diff_chars_removed",
    "diff_sentences_removed",
    "diff_frontmatter_changed",
    "diff_memo_changed",
    "diff_sources_changed",
    "diff_unresolved_marks_added",
    "diff_new_urls",
    "diff_numbers_added",
    "diff_numbers_removed",
    "diff_report_mismatch",
)
_VDIFF_LIST_MAX = 10
_VDIFF_ITEM_MAX = 200
_URL_RE = re.compile(r"https?://[^\s)\]>\"'`]+")
_NUMBER_TOKEN_RE = re.compile(r"\d+(?:[.,:/-]\d+)*")
_UNRESOLVED_MARK_RE = re.compile(r"[ \t]*[（(]未解決[^）)\n]*[）)]")
_SENTENCE_SPLIT_RE = re.compile(r"(?<=[。！？])|\n")
_REPORTED_RE = re.compile(
    r"検証[:：]\s*(\d+)\s*件\s*[(（]\s*supported\s*(\d+)\s*/\s*partial\s*(\d+)\s*/\s*"
    r"unsupported\s*(\d+)\s*/\s*unverifiable\s*(\d+)"
)
_REPORTED_EDITS_RE = re.compile(r"修正 span 合計[:：]\s*(\d+|無変更)")


# 末尾の固定 2 節の見出し行 (完全一致)。「## ソースコード…」のような本文の見出しを固定節と取り違えない。
# 同じ見出しが本文にもあれば最後の 1 つを固定節とみなす (固定節は 機会メモ → ソース の順で末尾 — templates)
_TAIL_MEMO_RE = re.compile(r"^## 機会メモ[ \t]*$", re.MULTILINE)
_TAIL_SOURCES_RE = re.compile(r"^## ソース[ \t]*$", re.MULTILINE)


def _last_line_match(pattern: re.Pattern[str], text: str) -> int:
    """text の中で pattern に一致する最後の行の開始位置。無ければ -1。"""
    pos = -1
    for m in pattern.finditer(text):
        pos = m.start()
    return pos


def _tail_split(text: str) -> tuple[int, int]:
    """(機会メモ節の開始, ソース節の開始)。無い節は -1。機会メモはソース節より前だけを探す。"""
    src_at = _last_line_match(_TAIL_SOURCES_RE, text)
    memo_at = _last_line_match(_TAIL_MEMO_RE, text[:src_at] if src_at >= 0 else text)
    return memo_at, src_at


def _note_parts(text: str) -> tuple[str, str, str]:
    """(frontmatter, 機会メモ節, ソース節) を返す。無い節は空文字。"""
    m = _FRONTMATTER_RE.match(text)
    fm = m.group(0) if m else ""
    rest = text[len(fm) :]
    memo_at, src_at = _tail_split(rest)
    sources = rest[src_at:] if src_at >= 0 else ""
    memo = rest[memo_at : src_at if src_at >= 0 else len(rest)] if memo_at >= 0 else ""
    return fm, memo, sources


def _clip_list(items: list[str]) -> list[str]:
    return [_CTRL_RE.sub(" ", str(x))[:_VDIFF_ITEM_MAX] for x in items[:_VDIFF_LIST_MAX]]


def _sentence_diff(pre: str, post: str) -> tuple[int, int, int, int]:
    """文単位の差分 (spans, chars_added, chars_removed, sentences_removed)。"""
    import difflib

    def units(t: str) -> list[str]:
        return [u.strip() for u in _SENTENCE_SPLIT_RE.split(t) if u and u.strip()]

    a, b = units(pre), units(post)
    spans = added = removed = sentences_removed = 0
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        spans += 1
        sentences_removed += max(0, (i2 - i1) - (j2 - j1))
        old, new = "".join(a[i1:i2]), "".join(b[j1:j2])
        for ctag, c1, c2, d1, d2 in difflib.SequenceMatcher(
            None, old, new, autojunk=False
        ).get_opcodes():
            if ctag != "equal":
                removed += c2 - c1
                added += d2 - d1
    return spans, added, removed, sentences_removed


def _reported_counts(raw: str) -> dict[str, int | None] | None:
    """呼2 の完了報告から件数を読む。読めなければ None。"""
    try:
        d = _result_dict(json.loads(raw or "null")) or {}
    except (ValueError, TypeError):
        return None
    text = d.get("result") if isinstance(d, dict) else None
    m = _REPORTED_RE.search(text) if isinstance(text, str) else None
    if not m:
        return None
    total, sup, par, uns, unv = (int(g) for g in m.groups())
    em = _REPORTED_EDITS_RE.search(text)
    edits = None if not em else (0 if em.group(1) == "無変更" else int(em.group(1)))
    return {
        "total": total,
        "supported": sup,
        "partial": par,
        "unsupported": uns,
        "unverifiable": unv,
        "edits": edits,
    }


def _report_mismatch(
    verify: dict[str, int] | None, reported: dict[str, int | None] | None
) -> list[str]:
    """verify.json と完了報告の食い違いを "key verify≠reported" の list で返す。"""
    if verify is None or reported is None:
        return []
    out = [
        f"{k} {verify[k]}≠{reported[k]}"
        for k in ("supported", "partial", "unsupported", "unverifiable")
        if verify[k] != reported[k]
    ]
    vtotal = sum(verify[k] for k in ("supported", "partial", "unsupported", "unverifiable"))
    if vtotal != reported["total"]:
        out.append(f"total {vtotal}≠{reported['total']}")
    if reported["edits"] is not None and verify["edits"] != reported["edits"]:
        out.append(f"edits {verify['edits']}≠{reported['edits']}")
    return out


def cmd_verify_diff(argv: list[str]) -> int:
    from collections import Counter

    if len(argv) < 2:
        print("usage: verify-diff <pre_path> <post_path> [verify_json_path]", file=sys.stderr)
        return 64
    pre_path, post_path = argv[:2]
    verify_path = argv[2] if len(argv) >= 3 else ""
    try:
        with open(pre_path, encoding="utf-8") as f:
            pre = f.read()
        with open(post_path, encoding="utf-8") as f:
            post = f.read()
    except (OSError, UnicodeDecodeError) as e:
        print(f"verify-diff: {e}", file=sys.stderr)
        return 1
    verify = None
    if verify_path:
        try:
            with open(verify_path) as f:
                vd = json.load(f)
            if isinstance(vd, dict):
                verify = {k: _nonneg_int(vd.get(k)) for k in VERIFY_KEYS}
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            verify = None

    spans, added, removed, sentences_removed = _sentence_diff(pre, post)
    pre_fm, pre_memo, pre_src = _note_parts(pre)
    post_fm, post_memo, post_src = _note_parts(post)

    def unmarked(t: str) -> str:
        return _UNRESOLVED_MARK_RE.sub("", t)

    def numbers(t: str, fm: str) -> Counter[str]:
        return Counter(_NUMBER_TOKEN_RE.findall(unmarked(t[len(fm) :])))

    # URL は「(未解決 …)」の付記を除いた本文から取る — 裸 URL の直後に付いた付記を URL の一部と読まない
    pre_urls = set(_URL_RE.findall(unmarked(pre)))
    new_urls = sorted({u for u in _URL_RE.findall(unmarked(post)) if u not in pre_urls})
    n_pre, n_post = numbers(pre, pre_fm), numbers(post, post_fm)
    nums_added = sorted((n_post - n_pre).elements())
    nums_removed = sorted((n_pre - n_post).elements())
    reported = _reported_counts(sys.stdin.read())
    mismatch = _report_mismatch(verify, reported)

    out = {
        "diff_spans": spans,
        "diff_chars_added": added,
        "diff_chars_removed": removed,
        "diff_sentences_removed": sentences_removed,
        "diff_frontmatter_changed": pre_fm != post_fm,
        "diff_memo_changed": pre_memo.strip() != post_memo.strip(),
        "diff_sources_changed": unmarked(pre_src).strip() != unmarked(post_src).strip(),
        "diff_unresolved_marks_added": max(
            0, len(_UNRESOLVED_MARK_RE.findall(post)) - len(_UNRESOLVED_MARK_RE.findall(pre))
        ),
        "diff_new_urls": len(new_urls),
        "diff_numbers_added": len(nums_added),
        "diff_numbers_removed": len(nums_removed),
        "diff_report_mismatch": bool(mismatch),
        "new_urls": _clip_list(new_urls),
        "numbers_added": _clip_list(nums_added),
        "numbers_removed": _clip_list(nums_removed),
        "reported": reported,
        "mismatch": mismatch,
    }
    print(json.dumps(out, ensure_ascii=False))
    if mismatch:
        print(f"verify.json と完了報告の件数が食い違う ({', '.join(mismatch)})")
    if out["diff_frontmatter_changed"]:
        print("frontmatter が改稿された (呼2 の禁止事項)")
    if out["diff_memo_changed"]:
        print("機会メモ節が改稿された (呼2 の禁止事項)")
    if out["diff_sources_changed"]:
        print("ソース節が未解決の付記以外で改稿された (呼2 の禁止事項)")
    if new_urls:
        print(f"原稿に無かった URL が {len(new_urls)} 件増えた (呼2 の禁止事項)")
    return 0


def _sum_vdiff(vdiffs: list[dict[str, object]]) -> dict[str, int]:
    """VDIFF 行群の diff_* を合算する (bool は 0/1)。diff_lines = 行数。一覧は log にだけ残す。"""
    total = {k: 0 for k in VDIFF_SUM_KEYS}
    for v in vdiffs:
        for k in VDIFF_SUM_KEYS:
            x = v.get(k)
            total[k] += int(x) if isinstance(x, bool) else _nonneg_int(x)
    total["diff_lines"] = len(vdiffs)
    return total


# --- pending-stats <pending_path> [report_path]: pending.md の項目数・字数と、記事の機会メモの項目数 ---
# stdout: "items<TAB>chars<TAB>memo_items"。SH が呼1 の前後に回し、hold 以外の run で items の増分が
# memo_items (記事の機会メモ = 日付付き締切の機会の数) を超えたら WARN にする (両プロトコル Step 6:
# 項目を足すのは hold の問いと日付付き締切の機会だけ)。
# 項目 = 「### 」「#### 」の見出し行・「- **」で始まる箇条・表のデータ行 (見出し行と区切り行を除く)。
# pending.md の書式は line ごとに違う (箇条 / 見出し / 表) ので 3 つとも数える。「## 」の節見出しと
# 平の箇条 (状態更新の行) は数えない。ファイルが無ければ 0。
_TABLE_SEP_RE = re.compile(r"^\|[\s:|-]+\|?\s*$")
_MEMO_ITEM_RE = re.compile(r"^\s*- \*\*何を\*\*", re.MULTILINE)


def _pending_items(text: str) -> int:
    lines = text.splitlines()
    n = 0
    for i, ln in enumerate(lines):
        if ln.startswith("|"):
            nxt = lines[i + 1] if i + 1 < len(lines) else ""
            if not _TABLE_SEP_RE.match(ln) and not _TABLE_SEP_RE.match(nxt):
                n += 1
        elif ln.startswith(("### ", "#### ", "- **")):
            n += 1
    return n


def cmd_pending_stats(argv: list[str]) -> int:
    if not argv:
        print("usage: pending-stats <pending_path> [report_path]", file=sys.stderr)
        return 64

    def read(path: str) -> str:
        try:
            with open(path, encoding="utf-8") as f:
                return f.read()
        except (OSError, UnicodeDecodeError):
            return ""

    text = read(argv[0])
    memo_items = 0
    if len(argv) >= 2 and argv[1]:
        _, memo, _ = _note_parts(read(argv[1]))
        memo_items = len(_MEMO_ITEM_RE.findall(memo))
    print(f"{_pending_items(text)}\t{len(text)}\t{memo_items}")
    return 0


# --- config-get <config_path> <section.key> [default]: config の 1 値を出力 ---
# 値が無い・config が読めない場合は default (省略時は空行)。bool は true/false。
def cmd_config_get(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: config-get <config_path> <section.key> [default]", file=sys.stderr)
        return 64
    config_path, dotted = argv[:2]
    default = argv[2] if len(argv) >= 3 else ""
    try:
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


def _pass_metrics(d: object) -> dict[str, float]:
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


def _load_metrics(metrics_path: str, include_test: bool = False) -> list[dict[str, object]]:
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
                if not isinstance(rec, dict):
                    continue
                if not include_test and rec.get("source") == "test":
                    continue
                records.append(rec)
    except FileNotFoundError:
        pass
    return records


def _sum_pass_metrics(dicts: list[dict[str, float]]) -> dict[str, float] | None:
    """複数 run の _pass_metrics dict を合算する (per-repo 実行の pass2 集約)。"""
    if not dicts:
        return None
    total: dict[str, float] = {
        k: 0 for k in ("cost", "turns", "duration_s", "tokens_in", "tokens_out", "searches")
    }
    for d in dicts:
        for k in total:
            total[k] += d.get(k, 0)
    total["cost"] = round(total["cost"], 4)
    return total


def _total_cost(record: dict[str, object]) -> float:
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


def _sum_verification(verifies: list[dict[str, object]]) -> dict[str, int] | None:
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
#   VDIFF\t{json}        — verify-diff の 1 行目。diff_* を verification に合算、diff_lines = 行数
#                        (VDIFF 行が無い日は verification に diff_* を足さない — 旧 record と同じ形)
# ラベル不明・payload 破損の行は skip (収集は non-fatal)。
# pass1 は per-repo 化で廃止 (None 固定)。第 5 引数はリトライ発生の有無で、
# レコード互換のため旧フィールド名 fallback_used に記録する。
# clarity_pass (ADR-0010): verdict やスコアは保存しない (in-loop 型 — 消費は
# run 内で完結し、ここは発動事実のみ)。
def cmd_metrics_append(argv: list[str]) -> int:
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
    verifies, vdiffs = [], []
    for line in sys.stdin.read().split("\n"):
        line = line.strip()
        if not line:
            continue
        label, _, payload = line.partition("\t")
        if label == "VDIFF":
            try:
                v = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if isinstance(v, dict):
                vdiffs.append(v)
        elif label == "STATE":
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
    if record["verification"] is not None and vdiffs:
        record["verification"].update(_sum_vdiff(vdiffs))
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
def cmd_metrics_backfill(argv: list[str]) -> int:
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


def _frontmatter_kind(text: str) -> str:
    """先頭 YAML frontmatter の kind: を返す (無ければ article)。"""
    m = re.match(r"---\n(.*?)\n---", text, re.DOTALL)
    if m:
        k = re.search(r"^kind:\s*[\"']?([A-Za-z_-]+)", m.group(1), re.MULTILINE)
        if k:
            return k.group(1)
    return "article"


_FRONTMATTER_RE = re.compile(r"---\n.*?\n---\n?", re.DOTALL)
_H1_RE = re.compile(r"^# .*$", re.MULTILINE)
_BODY_HEADING_RE = re.compile(r"^#{2,3} ", re.MULTILINE)


def _report_body(text: str) -> str:
    """ノートの本文を返す: frontmatter と H1 行の後から、末尾固定節の「## 機会メモ」(無ければ「## ソース」)
    の前まで。H1 が無ければ frontmatter の直後から、固定節が無ければ末尾まで。"""
    m = _FRONTMATTER_RE.match(text)
    rest = text[m.end() :] if m else text
    h1 = _H1_RE.search(rest)
    after = rest[h1.end() :] if h1 else rest
    memo_at, src_at = _tail_split(after)
    end = memo_at if memo_at >= 0 else src_at
    return after[:end] if end >= 0 else after


# --- report-lint <report_dir> <date> [config_path] ---
# 当日レポートの決定論的品質検査 (ctl-016)。stdout に JSON 1 行。
# exit 0 = 全 PASS または soft violation のみ / 2 = hard fail あり。
# hard: ソース節不在・出典 URL 0 件 (レポートの体を成していない)
# soft: 出典 < min_sources / 必須節欠落 / 本文長不足 (本文 = _report_body の空白を除いた字数)
# results[] の長さの記録 (閾値は持たない、ADR-0014 D6):
#   body_chars    本文の空白を除いた字数 (見出し行を含む)。dr-review が kind 別に 3,000 / 600 字と比べる
#   file_chars    ファイル全体の長さ。2026-11-08 以前の record の body_chars はこの値 — file_chars の有無で
#                 定義を見分ける (無い record の body_chars はファイル長)
#   body_headings 本文の ##・### 見出しの数 (両プロトコルの目安は 2 個まで)
# kind (ADR-0017): frontmatter の kind: を読む (無ければ article)。brief (短報) は
# 必須節 (機会メモ) と本文長の soft を免除し、hard と出典数 soft は article と同じ。
# 必須節は自由形式レポート (ADR-0009) の機械検査対象 — 機会メモのみ
# (ソース節は hard 判定として別途検査)。本文の記述規律は人間 consumer が判断する。
def cmd_report_lint(argv: list[str]) -> int:
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

        body = _report_body(text)
        body_chars = len(re.sub(r"\s", "", body))
        if kind != "brief" and body_chars < MIN_BODY_CHARS:
            soft.append(f"本文 {body_chars} 字 (< {MIN_BODY_CHARS})")

        results.append(
            {
                "file": name,
                "kind": kind,
                "hard": hard,
                "soft": soft,
                "body_chars": body_chars,
                "file_chars": len(text),
                "body_headings": len(_BODY_HEADING_RE.findall(body)),
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
def cmd_wiki_quality_scan(argv: list[str]) -> int:
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

    def line_of_stem(stem: str) -> str:
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
def cmd_review_age(argv: list[str]) -> int:
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
def cmd_expect_check(argv: list[str]) -> int:
    if len(argv) < 1:
        print("usage: expect-check <metrics_path>  (expects on stdin)", file=sys.stderr)
        return 64
    records = _load_metrics(argv[0])

    def percentile(vals: list[float], p: int) -> float | None:
        vals = sorted(vals)
        if not vals:
            return None
        i = min(len(vals) - 1, max(0, round(p / 100 * (len(vals) - 1))))
        return vals[i]

    def metric_value(name: str, recs: list[dict[str, object]]) -> float | None:
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

    def receipts(s: dict[str, int]) -> int:
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
    "monthly_cap_usd": 100.0,
    "daily_cap_usd": 10.0,
    "call1_max_usd": 4.0,
    "call2_max_usd": 1.5,
}


def _billing(cfg: dict[str, object]) -> dict[str, str | float]:
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
def cmd_billing_config(argv: list[str]) -> int:
    if not argv:
        print("usage: billing-config <config_path>", file=sys.stderr)
        return 64
    try:
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
def cmd_env_key(argv: list[str]) -> int:
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


_LEDGER_DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")  # 台帳の date (spend-add が書く形)


def _spend_totals(ledger: str, date_s: str) -> tuple[float, float, list[str]]:
    """(month_total, day_total, unreadable)。unreadable は読めない行の "line N (理由)" で、
    呼ぶ側が名指して止める — 黙って捨てるとその費用が累計から消え、上限の判定が甘くなる。
    行ごとに UTF-8 として decode する: 壊れた byte はその行だけを読めない行にし、台帳全体の
    UnicodeDecodeError (traceback = rc 1 = 「上限で止めた」と読まれる) にしない。
    台帳が無いのは 0 円 (初回)。開けないのは OSError のまま呼ぶ側へ。"""
    month, day, unreadable = 0.0, 0.0, []
    try:
        with open(ledger, "rb") as f:
            raw_lines = f.read().splitlines()
    except FileNotFoundError:
        return month, day, unreadable
    for n, raw in enumerate(raw_lines, 1):
        try:
            line = raw.decode("utf-8")
        except UnicodeDecodeError:
            unreadable.append(f"line {n} (not UTF-8)")
            continue
        if not line.strip():
            continue
        try:
            r = json.loads(line)
        except ValueError:
            unreadable.append(f"line {n} (not JSON)")
            continue
        except RecursionError:  # 深い入れ子。ValueError でないので別に捕まえる
            unreadable.append(f"line {n} (too deeply nested)")
            continue
        if not isinstance(r, dict):
            unreadable.append(f"line {n} (not an object)")
            continue
        # spend-add は cost_usd を必ず数で書く。無い・null の行 (手で編集した台帳) を 0 ドルに
        # 数えると、その費用が累計から黙って消える。偽値 ("" / {}) も 0 に読み替えない
        if r.get("cost_usd") is None:
            unreadable.append(f"line {n} (no cost_usd)")
            continue
        try:
            c = float(r["cost_usd"])
        except (ValueError, TypeError, OverflowError):  # OverflowError: float に収まらない整数
            unreadable.append(f"line {n} (cost_usd is not a number)")
            continue
        # 費用は有限の 0 以上。負は累計を減らして上限を緩め、NaN / inf (json.loads が既定で
        # 受け付ける) は判定を金額 nan / inf の stop にしてどの行が原因かを消す
        if not math.isfinite(c):
            unreadable.append(f"line {n} (cost_usd is not finite)")
            continue
        if c < 0:
            unreadable.append(f"line {n} (cost_usd is negative)")
            continue
        # date で月・日に振り分ける。YYYY-MM-DD でない行はどの累計にも入らず 0 ドルと同じになる
        d = r.get("date")
        if d is None:
            unreadable.append(f"line {n} (no date)")
            continue
        if not isinstance(d, str) or not _LEDGER_DATE_RE.fullmatch(d):
            unreadable.append(f"line {n} (date is not YYYY-MM-DD)")
            continue
        if d[:7] == date_s[:7]:
            month += c
            if d == date_s:
                day += c
    return month, day, unreadable


# --- spend-add <ledger> <date> <line> <call> [fallback_usd]: stdin の claude JSON の費用を台帳に追記 ---
# JSON に total_cost_usd が無い (timeout で kill された・解析失敗) ときは、その呼び出しが使えた
# 上限額 fallback_usd を "estimated": true 付きで記録する — 0 円にすると、使ったかもしれない額が
# 累計から消えて上限の判定が甘くなる。追記した費用を出力。書けなければ rc 1。
def cmd_spend_add(argv: list[str]) -> int:
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
# rc 2 の stderr は理由 (読めない行は "line N (理由)") を 1 行で出す — billing.sh が log に写す。
def cmd_spend_gate(argv: list[str]) -> int:
    if len(argv) < 5:
        print(
            "usage: spend-gate <ledger> <date> <monthly_cap> <daily_cap> <reserve>", file=sys.stderr
        )
        return 64
    ledger, date_s = argv[:2]
    monthly, daily, reserve = (float(x) for x in argv[2:5])
    try:
        month, day, unreadable = _spend_totals(ledger, date_s)
    except OSError as e:
        print(f"spend-gate: cannot read {ledger}: {e}", file=sys.stderr)
        return 2
    if unreadable:
        # 読めない行の費用は分からない。数えられない支出があるまま上限を判定しない。
        # stderr は billing.sh が log の 1 行に載せるので、名指す行は先頭 5 件まで
        named = ", ".join(unreadable[:5])
        rest = f", and {len(unreadable) - 5} more" if len(unreadable) > 5 else ""
        print(
            f"spend-gate: {len(unreadable)} unreadable line(s) in {ledger}: {named}{rest}",
            file=sys.stderr,
        )
        return 2
    ok = monthly - month >= reserve and daily - day >= reserve
    print(f"{'ok' if ok else 'stop'}\t{month:.2f}\t{day:.2f}")
    return 0 if ok else 1


COMMANDS: dict[str, Callable[[list[str]], int]] = {
    "error-fields": cmd_error_fields,
    "log-summary": cmd_log_summary,
    "vault-path": cmd_vault_path,
    "report-dir": cmd_report_dir,
    "template-path": cmd_template_path,
    "tracks": cmd_tracks,
    "rotation-pick": cmd_rotation_pick,
    "past-themes": cmd_past_themes,
    "past-topics-append": cmd_past_topics_append,
    "repo-activity": cmd_repo_activity,
    "line-brief": cmd_line_brief,
    "receipt-read": cmd_receipt_read,
    "verify-read": cmd_verify_read,
    "verify-diff": cmd_verify_diff,
    "pending-stats": cmd_pending_stats,
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


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in COMMANDS:
        print(f"usage: dr_pipeline.py <{' | '.join(COMMANDS)}> [args]", file=sys.stderr)
        return 64
    return COMMANDS[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
