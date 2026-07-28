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
    return cfg, tracks


def _track_repos(track_cfg):
    """line 定義の repos 配列を返す。無ければ [] (= 自由探索ライン)。"""
    repos = track_cfg.get("repos", [])
    return repos if isinstance(repos, list) else []


# --- parse-stream: stream-json NDJSON を集約し result イベント + tool_counts を出力 ---
def cmd_parse_stream(argv):
    tool_counts = {}
    result_event = None
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except Exception:
            continue
        etype = event.get("type")
        if etype == "assistant":
            for block in event.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    name = block.get("name", "unknown")
                    tool_counts[name] = tool_counts.get(name, 0) + 1
        elif etype == "result":
            result_event = event
    if result_event is not None:
        result_event["tool_counts"] = tool_counts
        print(json.dumps(result_event, ensure_ascii=False))
        return 0
    print("No result event found in stream", file=sys.stderr)
    return 1


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


# --- total-summary: stdin 2 行 (Pass1 / Pass2 JSON) から合算サマリーを出力 ---
def cmd_total_summary(argv):
    try:
        lines = sys.stdin.read().splitlines()
        d1 = _result_dict(json.loads(lines[0]))
        d2 = _result_dict(json.loads(lines[1]))
        cost1 = d1.get("total_cost_usd", 0)
        cost2 = d2.get("total_cost_usd", 0)
        dur1 = round(d1.get("duration_ms", 0) / 1000)
        dur2 = round(d2.get("duration_ms", 0) / 1000)
        print(
            f"SUMMARY Total: cost=${cost1 + cost2:.4f} duration={dur1 + dur2}s (Pass1: ${cost1:.4f}, Pass2: ${cost2:.4f})"
        )
    except Exception as e:
        print(f"SUMMARY Total: (parse error: {e})")
    return 0


# --- validate-theme <config_path>: Pass 1 出力から theme JSON を抽出・検証 ---
def cmd_validate_theme(argv):
    config_path = argv[0]
    try:
        _, tracks = _load_tracks(config_path)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1
    valid_tracks = set(tracks.keys())
    expected_count = len(valid_tracks)
    # line ごとの寄与先 repo key allowlist (自由探索ラインは [])
    repo_keys = {
        name: [r.get("key") for r in _track_repos(v) if r.get("key")]
        for name, v in tracks.items()
    }

    if expected_count == 0:
        print("No tracks defined in config.toml", file=sys.stderr)
        return 1

    raw = sys.stdin.read().strip()

    # マークダウンコードフェンスを除去
    raw = re.sub(r"^```(?:json)?\s*", "", raw)
    raw = re.sub(r"\s*```\s*$", "", raw)

    # JSON 部分を抽出
    match = re.search(r"\{.*\}", raw, re.DOTALL)
    if not match:
        print("No JSON object found", file=sys.stderr)
        return 1

    try:
        d = json.loads(match.group())
    except json.JSONDecodeError as e:
        print(f"JSON parse error: {e}", file=sys.stderr)
        return 1

    themes = d.get("themes", [])
    if not isinstance(themes, list) or len(themes) != expected_count:
        print(
            f"Expected {expected_count} themes, got {len(themes) if isinstance(themes, list) else type(themes).__name__}",
            file=sys.stderr,
        )
        return 1

    seen_tracks = set()
    for i, t in enumerate(themes):
        # Pass 1 出力は untrusted。dict 以外の要素は後段の t["..."] アクセスで
        # traceback になる前に明示的に弾く。
        if not isinstance(t, dict):
            print(f"Theme {i}: must be an object", file=sys.stderr)
            return 1
        for k in ("track", "topic", "slug", "score", "rationale"):
            if k not in t:
                print(f'Theme {i}: missing key "{k}"', file=sys.stderr)
                return 1
        track = t["track"]
        if not isinstance(track, str) or track not in valid_tracks:
            print(
                f'Theme {i}: invalid track "{track}" (valid: {sorted(valid_tracks)})',
                file=sys.stderr,
            )
            return 1
        # 同一 line への重複テーマは、themes 数 = line 数の検査だけでは検出できず
        # 他の line のテーマ枠を静かに奪う。distinctness を明示検査する。
        if track in seen_tracks:
            print(f'Theme {i}: duplicate track "{track}"', file=sys.stderr)
            return 1
        seen_tracks.add(track)
        keys = repo_keys[track]

        # repos: 寄与先 repo key 配列。repo-backed line は非空 + allowlist、
        # 自由探索 line (repos 未定義) は空でなければならない。
        repos = t.get("repos", [])
        if not isinstance(repos, list) or not all(isinstance(r, str) for r in repos):
            print(f"Theme {i}: repos must be a list of strings", file=sys.stderr)
            return 1
        if keys:
            if not repos:
                print(
                    f'Theme {i}: repos required for repo-backed track "{t["track"]}" (valid: {keys})',
                    file=sys.stderr,
                )
                return 1
            bad = [r for r in repos if r not in keys]
            if bad:
                print(
                    f'Theme {i}: invalid repos {bad} for track "{t["track"]}" (valid: {keys})',
                    file=sys.stderr,
                )
                return 1
        elif repos:
            print(
                f'Theme {i}: free-exploration track "{t["track"]}" must not have repos',
                file=sys.stderr,
            )
            return 1
        t["repos"] = repos

        # mode: repo-backed line は coverage | frontier、自由探索 line は explore。
        # 省略時は default に正規化して書き戻す (Pass 2 が graph.jsonld に記録する)。
        # 非 str (list/dict 等) は set 照合前に弾く (unhashable TypeError 防止)。
        allowed_modes = {"coverage", "frontier"} if keys else {"explore"}
        mode = t.get("mode") or ("coverage" if keys else "explore")
        if not isinstance(mode, str) or mode not in allowed_modes:
            print(
                f'Theme {i}: invalid mode "{mode}" for track "{track}" (valid: {sorted(allowed_modes)})',
                file=sys.stderr,
            )
            return 1
        t["mode"] = mode

        # 関係フィールド (reinforces / challenges / extends): concept @id 配列。
        # Sonnet が graph.jsonld に転記するため、JSON-LD を壊しうる文字
        # (引用符 / 制御文字 / 空白) を許さない allowlist で検証する。
        rels = {}
        for k in ("reinforces", "challenges", "extends"):
            vals = t.get(k, [])
            if not isinstance(vals, list):
                print(f"Theme {i}: {k} must be a list", file=sys.stderr)
                return 1
            for r in vals:
                if not isinstance(r, str) or not re.fullmatch(
                    r"[A-Za-z0-9_./:~#-]+", r
                ):
                    print(f'Theme {i}: invalid {k} entry "{r}"', file=sys.stderr)
                    return 1
            rels[k] = vals
            t[k] = vals
        # mode 別の非空条件: coverage は補強が主目的で reinforces 必須。frontier は
        # 挑戦・拡張を含めいずれか 1 つ以上。explore は repo concept を参照しない。
        if mode == "coverage" and not rels["reinforces"]:
            print(
                f"Theme {i}: coverage theme requires non-empty reinforces",
                file=sys.stderr,
            )
            return 1
        if mode == "frontier" and not (
            rels["reinforces"] or rels["challenges"] or rels["extends"]
        ):
            print(
                f"Theme {i}: frontier theme requires at least one of reinforces/challenges/extends",
                file=sys.stderr,
            )
            return 1
        if mode == "explore" and (
            rels["reinforces"] or rels["challenges"] or rels["extends"]
        ):
            print(
                f"Theme {i}: explore theme must not reference repo concepts",
                file=sys.stderr,
            )
            return 1

        if not isinstance(t["slug"], str) or not re.fullmatch(r"[a-z0-9-]+", t["slug"]):
            print(f'Theme {i}: invalid slug "{t.get("slug")}"', file=sys.stderr)
            return 1
        # topic と rationale の文字数上限（プロンプトインジェクション緩和）
        if len(str(t.get("topic", ""))) > 200:
            print(f"Theme {i}: topic too long (max 200)", file=sys.stderr)
            return 1
        if len(str(t.get("rationale", ""))) > 500:
            print(f"Theme {i}: rationale too long (max 500)", file=sys.stderr)
            return 1

    print(json.dumps(d, ensure_ascii=False))
    return 0


# --- result-field: stdin の claude -p JSON から result フィールド文字列を出力 ---
def cmd_result_field(argv):
    # 他 subcommand と同様、解析不能でも traceback を出さず空文字を返す
    # (呼び出し側は空 → fallback / validation 失敗で正しく処理する)
    try:
        d = json.loads(sys.stdin.read())
        d = _result_dict(d) or {}
        print(d.get("result", ""))
    except Exception:
        pass
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


# --- themes-log <theme_json>: 選定テーマを 1 行ログ用に整形 ---
def cmd_themes_log(argv):
    d = json.loads(argv[0])
    themes = d.get("themes", [])
    parts = []
    for t in themes:
        meta = []
        repos = t.get("repos") or []
        if repos:
            meta.append("+".join(str(r) for r in repos))
        if t.get("mode"):
            meta.append(str(t["mode"]))
        prefix = t.get("track", "?") + (f"[{'/'.join(meta)}]" if meta else "")
        parts.append(f'{prefix}="{t.get("topic", "?")}"')
    print("Pass 1 themes: " + ", ".join(parts))
    return 0


# --- tracks [config_path]: "line<TAB>repo_key<TAB>target_repo" を出力 (1 repo 1 行) ---
def cmd_tracks(argv):
    config_path = argv[0] if argv else "config.toml"
    try:
        _, tracks = _load_tracks(config_path)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1
    for track, v in tracks.items():
        for r in _track_repos(v):
            key = r.get("key")
            repo = r.get("target_repo")
            if key and repo:
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


# --- graph-health <path>: graph.jsonld の健全性を区別して判定
#     (missing=2, parse=3, schema=4, ok=0) ---
def cmd_graph_health(argv):
    path = argv[0]
    try:
        with open(path) as f:
            g = json.load(f)
    except FileNotFoundError:
        print(f"graph not found: {path}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as e:
        print(f"graph JSON parse error: {e}", file=sys.stderr)
        return 3
    if not isinstance(g, dict) or "@graph" not in g:
        print("graph schema invalid: missing @graph", file=sys.stderr)
        return 4
    return 0


# --- 飽和 cluster 計算 (cluster-report / report-lint で共有) ---
def _listify(v):
    return v if isinstance(v, list) else ([v] if v else [])


def _cluster_counters(config_path, graph_path):
    """graph.jsonld を集計し (saturated_set, total, recent, broad, recent_days, top_n,
    recent_min) を返す。graph が読めなければ ValueError。"""
    from collections import Counter
    from datetime import date, timedelta

    top_n, recent_days, recent_min = 15, 90, 3
    try:
        tomllib = _tomllib()
        with open(config_path, "rb") as f:
            cov = tomllib.load(f).get("coverage", {})
        top_n = int(cov.get("saturated_top_n", top_n))
        recent_days = int(cov.get("saturated_recent_days", recent_days))
        recent_min = int(cov.get("saturated_recent_min", recent_min))
    except FileNotFoundError:
        pass

    try:
        with open(graph_path) as f:
            g = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        raise ValueError(f"cluster report unavailable: {e}")

    total, recent, broad = Counter(), Counter(), Counter()
    cutoff = (date.today() - timedelta(days=recent_days)).isoformat()
    for n in g.get("@graph", []):
        if n.get("@type") != "Article":
            continue
        subs = _listify(n.get("subCluster"))
        total.update(subs)
        if n.get("datePublished", "") >= cutoff:
            recent.update(subs)
        broad.update(_listify(n.get("broadCluster")))

    saturated = {c for c, _ in total.most_common(top_n)}
    saturated |= {c for c, cnt in recent.items() if cnt >= recent_min}
    return saturated, total, recent, broad, recent_days, top_n, recent_min


# --- cluster-report [config_path] [graph_path]: 飽和 cluster レポートを出力 ---
def cmd_cluster_report(argv):
    """graph.jsonld の subCluster 頻度を集計し、自由探索ライン向けの
    「飽和 cluster (選定禁止)」リストを出力する。旧 tech track の構造的飽和
    (固定 domains への偏り) を、既出領域への機構的な反発で再発防止する。"""
    config_path = argv[0] if len(argv) >= 1 else "config.toml"
    graph_path = argv[1] if len(argv) >= 2 else "graph.jsonld"

    try:
        saturated, total, recent, broad, recent_days, top_n, recent_min = (
            _cluster_counters(config_path, graph_path)
        )
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1

    print("=== Cluster saturation report (自由探索ライン用) ===")
    print("以下の飽和 cluster に主に属するテーマは選定禁止。既存 cluster から遠い、")
    print("低頻度・新規の領域を優先すること (セレンディピティ重視)。")
    print()
    print(f"飽和 cluster (全期間 top-{top_n} ∪ 直近{recent_days}日{recent_min}回以上):")
    for c in sorted(saturated, key=lambda c: (-total[c], c)):
        print(f"  - {c} (全期間 {total[c]} 回, 直近{recent_days}日 {recent[c]} 回)")
    print()
    print("broadCluster 分布 (参考 — 特定 broad への偏りに注意):")
    for c, cnt in broad.most_common():
        print(f"  - {c}: {cnt} 回")
    return 0


# --- coverage-report [config_path] [graph_path]: concept coverage を line/repo 単位で出力 ---
def cmd_coverage_report(argv):
    """各 repo graph (.repo-graphs/<key>.jsonld) の concept @id と graph.jsonld の
    関与履歴を突き合わせ、repo ごとに coverage / frontier モードを判定して
    Pass 1 プロンプト向けレポートを stdout に出す (旧 coverage-report.sh の
    inline python を parser-of-record へ移設)。

    厚い/薄い/未補強 の分類は reinforces のみで数える (挑戦・拡張は補強ではない)。
    『既出』表示と主ソース dedup は reinforces ∪ challenges ∪ extends で数える。"""
    import os
    from datetime import date

    config_path = argv[0] if len(argv) >= 1 else "config.toml"
    graph_path = argv[1] if len(argv) >= 2 else "graph.jsonld"

    try:
        cfg, tracks = _load_tracks(config_path)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 1
    frontier_threshold = int(cfg.get("coverage", {}).get("frontier_threshold", 0))

    def norm_cid(cid):
        # fragment 正規化: concept @id の "#" 以降を照合キーにする。
        # repo concept は完全 URI (https://...#concept/foo)、Pass の記録は
        # fragment (concept/foo) のことがあるため、# 以降で揃える。無ければ全体。
        return cid.split("#", 1)[1] if "#" in cid else cid

    reinforced, engaged = {}, {}
    try:
        with open(graph_path) as f:
            dg = json.load(f)
        for n in dg.get("@graph", []):
            if n.get("@type") != "Article":
                continue
            d_ = n.get("datePublished", "")
            name = n.get("name", n.get("@id", ""))
            for cid in n.get("reinforces") or []:
                reinforced.setdefault(norm_cid(cid), []).append((d_, name))
            for k in ("reinforces", "challenges", "extends"):
                for cid in n.get(k) or []:
                    engaged.setdefault(norm_cid(cid), []).append((d_, name))
    except FileNotFoundError:
        pass

    def has_type(n, t):
        typ = n.get("@type")
        return t == typ or (isinstance(typ, list) and t in typ)

    def trunc(s, n=72):
        return s if len(s) <= n else s[:n] + "…"

    today = date.today().isoformat()
    print(f"=== Concept coverage report (as of {today}) ===")
    print(
        "各 line の repo ごとに concept を補強回数で分類し、選定モードを判定している。"
    )
    print("- MODE: coverage — 未補強・薄い concept を優先補強する外部研究を選ぶ")
    print("  (厚い concept の再訪は新展開がある時のみ)")
    print("- MODE: frontier — coverage は完了済み。gap 埋めではなく、concept に")
    print("  挑戦・矛盾する研究、concept を拡張する研究、repo にまだ無い新 concept")
    print("  候補を探す。『常設フロンティア質問』を最優先の探索軸にすること")
    print("各 concept の『既出:』はその concept に言及した過去レポート。同じ外部研究")
    print(
        "(論文・プロジェクト) を主ソースとする再利用は禁止 (別 concept 宛てでも不可)。"
    )
    print()

    for track, v in tracks.items():
        repos = v.get("repos") if isinstance(v.get("repos"), list) else []
        if not repos:
            continue  # 自由探索ラインは cluster-report が担当
        print(f"Line: {track}")
        for r in repos:
            key = r.get("key", "?")
            graph_file = r.get("target_graph", f".repo-graphs/{key}.jsonld")
            repo_name = (r.get("target_repo", "") or "").rstrip("/").split("/")[-1]
            if not os.path.exists(graph_file):
                print(f"  Repo: {key}  (repo graph not synced: {graph_file})")
                print()
                continue
            with open(graph_file) as f:
                rg = json.load(f)
            concepts = [n for n in rg.get("@graph", []) if has_type(n, "Concept")]

            unc, thin, thick = [], [], []
            for c in concepts:
                cid = c.get("@id")
                name = c.get("name", cid)
                cnt = len(reinforced.get(norm_cid(cid), []))
                hits = sorted(engaged.get(norm_cid(cid), []))
                if cnt == 0 and not hits:
                    unc.append([f"{name}  [{cid}]"])
                elif cnt <= 2:
                    lines = [f"{name} (補強 {cnt} 回)  [{cid}]"]
                    lines += [f"    既出: {d} {trunc(t)}" for d, t in hits]
                    thin.append(lines)
                else:
                    lines = [f"{name} (補強 {cnt} 回)  [{cid}]"]
                    lines += [f"    既出: {d} {trunc(t)}" for d, t in hits[-3:]]
                    thick.append(lines)

            mode = (
                "frontier" if len(unc) + len(thin) <= frontier_threshold else "coverage"
            )
            print(
                f"  Repo: {key} (repo: {repo_name}, {len(concepts)} concepts)  MODE: {mode}"
            )

            questions = r.get("frontier_questions") or []
            if mode == "frontier":
                if questions:
                    print("    常設フロンティア質問 (最優先の探索軸):")
                    for q in questions:
                        print(f"      * {q}")
                groups = [
                    (
                        "全 concept (挑戦・矛盾・拡張の対象として再訪可):",
                        unc + thin + thick,
                    ),
                ]
            else:
                groups = [
                    ("未補強 (0 件) — 最優先:", unc),
                    ("薄い (1-2 件):", thin),
                    ("厚い (3+ 件) — 再訪は新展開時のみ:", thick),
                ]

            for label, group in groups:
                if group:
                    print(f"  {label}")
                    for lines in group:
                        print(f"    - {lines[0]}")
                        for ln in lines[1:]:
                            print(f"  {ln}")

            if mode == "coverage" and questions:
                print(
                    "  常設フロンティア質問 (副次ガイド — gap 補強と両立するなら優先):"
                )
                for q in questions:
                    print(f"    * {q}")

            # repo が既に取り込んだ外部文献 (ExternalReference)。
            # これらを主ソースとするテーマは選定禁止 (repo にとって新規性がない)。
            refs = [n for n in rg.get("@graph", []) if has_type(n, "ExternalReference")]
            if refs:
                print(
                    f"  repo 取り込み済み外部文献 ({len(refs)} 件) — これらを主ソースとするテーマは選定禁止:"
                )
                for ref in refs:
                    rname = ref.get("name", "")
                    rid = ref.get("@id", "")
                    url = (
                        rid
                        if rid.startswith("http") and "vocab#" not in rid
                        else (ref.get("url") or "")
                    )
                    suffix = f"  [{url}]" if url else ""
                    print(f"    - {trunc(rname, 80)}{suffix}")
            print()
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


# --- metrics-append <metrics_path> <date> <final_class> <report_count> <fallback:0|1> ---
# stdin 3 行: Pass1 JSON / Pass2 JSON / lint JSON (それぞれ空行可)。
def cmd_metrics_append(argv):
    from datetime import datetime

    if len(argv) < 5:
        print(
            "usage: metrics-append <metrics_path> <date> <final_class> "
            "<report_count> <fallback:0|1>",
            file=sys.stderr,
        )
        return 64
    metrics_path, date_s, final_class, report_count, fallback = argv[:5]

    lines = sys.stdin.read().split("\n")

    def parse_line(i):
        try:
            return json.loads(lines[i]) if i < len(lines) and lines[i].strip() else None
        except json.JSONDecodeError:
            return None

    p1, p2, lint = parse_line(0), parse_line(1), parse_line(2)
    record = {
        "date": date_s,
        "ts": datetime.now().isoformat(timespec="seconds"),
        "source": "live",
        "final_class": final_class,
        "report_count": int(report_count or 0),
        "fallback_used": fallback == "1",
        "pass1": _pass_metrics(p1) if p1 else None,
        "pass2": _pass_metrics(p2) if p2 else None,
        "lint": lint,
    }
    record["total_cost"] = round(
        sum(p["cost"] for p in (record["pass1"], record["pass2"]) if p), 4
    )
    with open(metrics_path, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")
    print(f"metrics: appended {date_s} ({final_class}, {report_count} reports)")
    return 0


_SUMMARY_RE = re.compile(
    r"\[([\d: -]+)\] SUMMARY (Pass[12]): cost=\$([\d.]+) turns=(\d+) "
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
                        run[label.lower()] = {
                            "cost": float(m.group(3)),
                            "turns": int(m.group(4)),
                            "duration_s": int(m.group(5)),
                            "tokens_in": int(m.group(6)),
                            "tokens_out": int(m.group(7)),
                            "searches": int(m.group(8) or 0),
                        }
                        continue
                    if "=== Fallback:" in line:
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
                run["total_cost"] = round(
                    sum(p["cost"] for p in (run["pass1"], run["pass2"]) if p), 4
                )
                if (run["date"], run["ts"]) in existing:
                    continue
                out.write(json.dumps(run, ensure_ascii=False) + "\n")
                appended += 1
    print(f"metrics: backfilled {appended} run(s) from {len(log_files)} log file(s)")
    return 0


# --- report-lint <report_dir> <date> [config_path] [graph_path] ---
# 当日レポートの決定論的品質検査 (ctl-016)。stdout に JSON 1 行。
# exit 0 = 全 PASS または soft violation のみ / 2 = hard fail あり。
# hard: ソース節不在・出典 URL 0 件 (レポートの体を成していない)
# soft: 出典 <5 / 必須節欠落 / 本文長不足 / 飽和 cluster 違反 (自由探索のみ)
def cmd_report_lint(argv):
    import os

    if len(argv) < 2:
        print(
            "usage: report-lint <report_dir> <date> [config_path] [graph_path]",
            file=sys.stderr,
        )
        return 64
    report_dir, date_s = argv[:2]
    config_path = argv[2] if len(argv) >= 3 else "config.toml"
    graph_path = argv[3] if len(argv) >= 4 else "graph.jsonld"

    MIN_SOURCES = 5
    MIN_BODY_CHARS = 1500
    ARTICLE_SECTIONS = ["なぜ今このテーマか", "背景", "現在の状況", "未解決の問い"]
    DIGEST_SECTIONS = ["今日の探索アングル", "総評"]

    # 飽和 cluster 違反: graph.jsonld の当日 Article (mode=explore) を
    # dr:topic/<report-stem> で結合して判定する。graph が読めなければ skip。
    saturated_by_stem = {}
    try:
        saturated, *_ = _cluster_counters(config_path, graph_path)
        with open(graph_path) as f:
            for n in json.load(f).get("@graph", []):
                if n.get("@type") != "Article" or n.get("datePublished") != date_s:
                    continue
                if n.get("mode") != "explore":
                    continue  # cluster 反発は自由探索ラインのみ
                stem = n.get("@id", "").removeprefix("dr:topic/")
                hits = [c for c in _listify(n.get("subCluster")) if c in saturated]
                if stem and hits:
                    saturated_by_stem[stem] = hits
    except (ValueError, OSError, json.JSONDecodeError):
        pass

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
        elif n_sources < MIN_SOURCES:
            soft.append(f"出典 URL {n_sources} 件 (< {MIN_SOURCES})")

        is_digest = "## 今日の探索アングル" in text
        required = DIGEST_SECTIONS if is_digest else ARTICLE_SECTIONS
        missing = [s for s in required if f"## {s}" not in text]
        if missing:
            soft.append(f"必須節欠落: {', '.join(missing)}")

        if len(text) < MIN_BODY_CHARS:
            soft.append(f"本文 {len(text)} 字 (< {MIN_BODY_CHARS})")

        stem = name[:-3]
        if stem in saturated_by_stem:
            soft.append(f"飽和 cluster 違反: {', '.join(saturated_by_stem[stem])}")

        results.append({"file": name, "hard": hard, "soft": soft})

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
    "parse-stream": cmd_parse_stream,
    "error-fields": cmd_error_fields,
    "log-summary": cmd_log_summary,
    "total-summary": cmd_total_summary,
    "validate-theme": cmd_validate_theme,
    "result-field": cmd_result_field,
    "vault-path": cmd_vault_path,
    "report-dir": cmd_report_dir,
    "themes-log": cmd_themes_log,
    "tracks": cmd_tracks,
    "past-themes": cmd_past_themes,
    "graph-health": cmd_graph_health,
    "cluster-report": cmd_cluster_report,
    "coverage-report": cmd_coverage_report,
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
