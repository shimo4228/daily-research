#!/usr/bin/env python3
"""dr_pipeline — daily-research の JSON/TOML 解析層を集約した単一モジュール。

これまで daily-research.sh に散在していた `python3 -c "..."` / heredoc を
subcommand に置き換える parser-of-record。test も本モジュールだけを対象にすれば
よくなり、source と test のコピペ drift (旧 test-log-summary.bats) を根絶する。

呼び出し:  python3 scripts/lib/dr_pipeline.py <subcommand> [args]
依存:      stdlib のみ (json / tomllib / re / collections)。pip 依存なし。
           config.toml 解析に python>=3.11 の tomllib を使う (tomli fallback あり)。
"""

import sys
import json
import re


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
        return next(
            (e for e in raw if isinstance(e, dict) and e.get("type") == "result"), {}
        )
    return raw


# --- config helpers: 1 line = N repos schema の解析 + 旧 schema 検出 guard ---
def _load_tracks(config_path):
    """config.toml を読み (cfg, tracks) を返す。旧 schema (tracks.X 直下に
    target_repo) を検出したら ValueError — 再編後のコードが旧 config のまま
    朝の実行を迎えて静かに誤動作する事故を防ぐ。"""
    tomllib = _tomllib()
    with open(config_path, "rb") as f:
        cfg = tomllib.load(f)
    tracks = cfg.get("tracks", {})
    for name, v in tracks.items():
        if isinstance(v, dict) and "target_repo" in v:
            raise ValueError(
                f"config uses the legacy schema: target_repo directly under [tracks.{name}]. "
                f"Migrate to [[tracks.{name}.repos]] entries (see config.example.toml)"
            )
        # daily は bool 限定。TOML で daily = "false" と書くと bool("false") is True で
        # 毎日実行が黙って有効になる事故を、起動時の schema check で fail-fast に落とす。
        if isinstance(v, dict) and "daily" in v and not isinstance(v["daily"], bool):
            raise ValueError(
                f"[tracks.{name}].daily must be a boolean (true/false), "
                f"got {v['daily']!r}"
            )
    return cfg, tracks


def _track_repos(track_cfg):
    """line 定義の repos 配列を返す。無ければ [] (= 自由探索ライン)。"""
    repos = track_cfg.get("repos", [])
    return repos if isinstance(repos, list) else []


def _track_rows(tracks):
    """全 line の (track, key, target_repo, daily) 行を config 記述順で返す。
    tracks / rotation-pick が共有する行構築の正本 — 輪番の単位・順序は
    この関数が定義する (二重実装で周期が黙って乖離するのを防ぐ)。
    daily = true の line は毎日実行され、輪番の周期には入らない。"""
    rows = []
    for track, v in tracks.items():
        daily = bool(v.get("daily"))
        for r in _track_repos(v):
            key = r.get("key")
            repo = r.get("target_repo")
            if key and repo:
                rows.append((track, key, repo, daily))
    return rows


# --- error-fields: stdin JSON から "api_error_status<TAB>is_error" を出力 (auth/401 判定用) ---
def cmd_error_fields(argv):
    try:
        d = json.loads(sys.stdin.read() or "null")
        d = _result_dict(d) or {}
        code = d.get("api_error_status")
        code = "" if code is None else code
        print(f"{code}\t{str(bool(d.get('is_error'))).lower()}")
    except Exception:
        print("\tparse-fail")
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
        tc = d.get("tool_counts", {})
        searches = tc.get("WebSearch", 0) + tc.get("WebFetch", 0)
        tool_str = f" searches={searches}" if searches else ""
        print(
            f"SUMMARY {label}: cost=${cost:.4f} turns={turns} duration={dur}s tokens_in={inp} tokens_out={out}{tool_str}"
        )
    except Exception as e:
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
# 出力形式は tracks と同じ "line<TAB>repo_key<TAB>target_repo"。1 行目は非 daily 行の
# 輪番選択 (date.toordinal() % 非daily行数。proleptic Gregorian 序数 — Unix epoch 日で
# 再実装すると位相がずれるので注意)、以降に daily = true の line の行が config 記述順で
# 続く (daily line は毎日実行され、輪番の周期を変えない)。daily の無い config では
# 従来どおり 1 行のみ。全行 daily の config では輪番行なしで daily 行のみ。
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
        _, tracks = _load_tracks(config_path)
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
        picked.append(rotating[day % len(rotating)])
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
        if line and t.get("title"):
            by_line[line].append(t)

    print("=== 過去テーマ履歴 (line 別直近 10 件) ===")
    print("以下と同じテーマ・同じ主ソース (論文・プロジェクト) の再選定は禁止。")
    print("後続研究・新展開を扱う場合のみ可 (rationale に何が新展開かを明記すること)。")
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
            title = t["title"][:120] + ("…" if len(t["title"]) > 120 else "")
            print(f"  - {t.get('date', '?')} {title}")
        print()
    return 0


# --- line-brief <config_path> <track>: per-repo 実行 (ADR-0008) のプロンプト注入用に
#     line 定義 (focus / sources / context_files / self_signals) を整形出力 ---
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

    print("### Line 定義 (config.toml より)")
    print()
    if v.get("name"):
        print(f"- name: {v['name']}")
    if v.get("focus"):
        print(f"- focus: {v['focus']}")
    sources = v.get("sources") or []
    if sources:
        print("- 探索の起点 (sources):")
        for s in sources:
            print(f"  - {s}")
    ctx = v.get("context_files") or []
    if ctx:
        print("- context_files (Step 1 で必ず Read。存在しないものは skip 可):")
        for c in ctx:
            print(f"  - {c}")
    signals = cfg.get("general", {}).get("self_signals") or []
    if signals:
        print(
            "- 自己シグナル (自己汚染ガード — これらに合致する成果物を「外部シグナル」"
        )
        print("  として数えない。第三者による言及・採用の観測は正当):")
        for s in signals:
            print(f"  - {s}")
    return 0


# === 自己改善ループ (ADR-0006): 計測の永続化と決定論 lint =====================
#
# consumer は人間 (/dr-review skill)。ここは判断材料の収集・整形のみを担い、
# LLM による品質再採点や自動改変は行わない。


def _pass_metrics(d):
    """claude -p result JSON から 1 pass 分の metric dict を抽出する。"""
    d = _result_dict(d) or {}
    tc = d.get("tool_counts", {})
    return {
        "cost": round(float(d.get("total_cost_usd", 0) or 0), 4),
        "turns": int(d.get("num_turns", 0) or 0),
        "duration_s": round((d.get("duration_ms", 0) or 0) / 1000),
        "tokens_in": int(d.get("usage", {}).get("input_tokens", 0) or 0),
        "tokens_out": int(d.get("usage", {}).get("output_tokens", 0) or 0),
        "searches": int(tc.get("WebSearch", 0)) + int(tc.get("WebFetch", 0)),
    }


def _load_metrics(metrics_path):
    """metrics.jsonl を list[dict] で返す。壊れた行は skip (収集は non-fatal)。"""
    records = []
    try:
        with open(metrics_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        pass
    return records


def _sum_pass_metrics(dicts):
    """複数 run の _pass_metrics dict を合算する (per-repo 実行の pass2 集約)。"""
    if not dicts:
        return None
    total = {
        k: 0
        for k in ("cost", "turns", "duration_s", "tokens_in", "tokens_out", "searches")
    }
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


# --- metrics-append <metrics_path> <date> <final_class> <report_count> <retry:0|1> ---
# stdin: 1 行 1 レコード、統一 framing "LABEL\t[meta\t]payload"。
#   RUN\t{json}          — claude -p result JSON。pass2 に合算 (ADR-0008 の写像)
#   LINT\t{json}         — report-lint (ctl-016) の JSON
#   CLARITY\t<ok:0|1>\t{json} — 呼2 clarity 改稿の発動記録 (ADR-0010)
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
            "<report_count> <retry:0|1>",
            file=sys.stderr,
        )
        return 64
    metrics_path, date_s, final_class, report_count, retry = argv[:5]

    runs, lint, clarities = [], None, []
    for line in sys.stdin.read().split("\n"):
        line = line.strip()
        if not line:
            continue
        label, _, payload = line.partition("\t")
        if label == "CLARITY":
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
        metric_dicts = [
            {k: v for k, v in c.items() if k not in ("ran", "ok")} for c in clarities
        ]
        summed = _sum_pass_metrics([m for m in metric_dicts if m])
        clarity = {
            "ran": True,
            "ok": all(c.get("ok") for c in clarities),
            **(summed or {}),
        }

    record = {
        "date": date_s,
        "ts": datetime.now().isoformat(timespec="seconds"),
        "source": "live",
        "final_class": final_class,
        "report_count": int(report_count or 0),
        "fallback_used": retry == "1",
        "pass1": None,
        "pass2": _sum_pass_metrics(runs),
        "clarity_pass": clarity,
        "lint": lint,
    }
    record["total_cost"] = _total_cost(record)
    with open(metrics_path, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")
    print(
        f"metrics: appended {date_s} ({final_class}, {report_count} reports, {len(runs)} runs)"
    )
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

    existing = {(r.get("date"), r.get("ts")) for r in _load_metrics(metrics_path)}
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


# --- report-lint <report_dir> <date> [config_path] ---
# 当日レポートの決定論的品質検査 (ctl-016)。stdout に JSON 1 行。
# exit 0 = 全 PASS または soft violation のみ / 2 = hard fail あり。
# hard: ソース節不在・出典 URL 0 件 (レポートの体を成していない)
# soft: 出典 < min_sources / 必須節欠落 / 本文長不足
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
            min_sources = int(
                tomllib.load(f).get("report", {}).get("min_sources", min_sources)
            )
    except (FileNotFoundError, ValueError, OSError):
        pass
    MIN_BODY_CHARS = 1500
    ARTICLE_SECTIONS = [
        "機会メモ",
    ]

    results = []
    try:
        files = sorted(
            f
            for f in os.listdir(report_dir)
            if f.startswith(f"{date_s}_") and f.endswith(".md")
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

        urls = re.findall(r"\[[^\]]*\]\((https?://[^)]+)\)", text)
        n_sources = len(set(urls))
        if "## ソース" not in text:
            hard.append("ソース節がない")
        if n_sources == 0:
            hard.append("出典 URL が 0 件")
        elif n_sources < min_sources:
            soft.append(f"出典 URL {n_sources} 件 (< {min_sources})")

        missing = [s for s in ARTICLE_SECTIONS if f"## {s}" not in text]
        if missing:
            soft.append(f"必須節欠落: {', '.join(missing)}")

        if len(text) < MIN_BODY_CHARS:
            soft.append(f"本文 {len(text)} 字 (< {MIN_BODY_CHARS})")

        results.append(
            {"file": name, "hard": hard, "soft": soft, "body_chars": len(text)}
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
                "reports": {
                    stem: sorted(set(pages)) for stem, pages in sorted(flagged.items())
                },
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
#   lint_hard_count
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
            return (
                max(vals)
                if m.group(2) == "max"
                else percentile(vals, int(m.group(2)[1:]))
            )
        m = re.fullmatch(r"(pass1|pass2|total)_cost_(mean|max)", name)
        if m:
            key = m.group(1)
            vals = [
                (
                    r.get("total_cost")
                    if key == "total"
                    else (r.get(key) or {}).get("cost")
                )
                for r in recs
            ]
            vals = [v for v in vals if v is not None]
            if not vals:
                return None
            return max(vals) if m.group(2) == "max" else sum(vals) / len(vals)
        if name == "fallback_rate":
            return (
                sum(1 for r in recs if r.get("fallback_used")) / len(recs)
                if recs
                else None
            )
        if name == "report_count_min":
            vals = [r.get("report_count", 0) for r in recs]
            return min(vals) if vals else None
        if name == "no_report_count":
            return sum(1 for r in recs if r.get("final_class") == "E_NO_REPORT")
        if name == "lint_hard_count":
            return sum((r.get("lint") or {}).get("hard_fail", 0) for r in recs)
        return None

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


COMMANDS = {
    "error-fields": cmd_error_fields,
    "log-summary": cmd_log_summary,
    "vault-path": cmd_vault_path,
    "report-dir": cmd_report_dir,
    "tracks": cmd_tracks,
    "rotation-pick": cmd_rotation_pick,
    "past-themes": cmd_past_themes,
    "line-brief": cmd_line_brief,
    "metrics-append": cmd_metrics_append,
    "metrics-backfill": cmd_metrics_backfill,
    "report-lint": cmd_report_lint,
    "wiki-quality-scan": cmd_wiki_quality_scan,
    "review-age": cmd_review_age,
    "expect-check": cmd_expect_check,
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        print(f"usage: dr_pipeline.py <{' | '.join(COMMANDS)}> [args]", file=sys.stderr)
        return 64
    return COMMANDS[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
