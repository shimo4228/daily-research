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
        return next((e for e in raw if isinstance(e, dict) and e.get('type') == 'result'), {})
    return raw


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
        d = json.loads(sys.stdin.read() or 'null')
        d = _result_dict(d) or {}
        code = d.get('api_error_status')
        code = '' if code is None else code
        print(f"{code}\t{str(bool(d.get('is_error'))).lower()}")
    except Exception:
        print('\tparse-fail')
    return 0


# --- log-summary <label>: claude -p JSON からサマリー行を出力 ---
def cmd_log_summary(argv):
    label = argv[0] if argv else '?'
    try:
        raw = json.loads(sys.stdin.read())
        d = _result_dict(raw)
        cost = d.get('total_cost_usd', 0)
        turns = d.get('num_turns', 0)
        dur = round(d.get('duration_ms', 0) / 1000)
        inp = d.get('usage', {}).get('input_tokens', 0)
        out = d.get('usage', {}).get('output_tokens', 0)
        tc = d.get('tool_counts', {})
        searches = tc.get('WebSearch', 0) + tc.get('WebFetch', 0)
        tool_str = f' searches={searches}' if searches else ''
        print(f'SUMMARY {label}: cost=${cost:.4f} turns={turns} duration={dur}s tokens_in={inp} tokens_out={out}{tool_str}')
    except Exception as e:
        print(f'SUMMARY {label}: (parse error: {e})')
    return 0


# --- total-summary: stdin 2 行 (Pass1 / Pass2 JSON) から合算サマリーを出力 ---
def cmd_total_summary(argv):
    try:
        lines = sys.stdin.read().splitlines()
        d1 = _result_dict(json.loads(lines[0]))
        d2 = _result_dict(json.loads(lines[1]))
        cost1 = d1.get('total_cost_usd', 0)
        cost2 = d2.get('total_cost_usd', 0)
        dur1 = round(d1.get('duration_ms', 0) / 1000)
        dur2 = round(d2.get('duration_ms', 0) / 1000)
        print(f'SUMMARY Total: cost=${cost1 + cost2:.4f} duration={dur1 + dur2}s (Pass1: ${cost1:.4f}, Pass2: ${cost2:.4f})')
    except Exception as e:
        print(f'SUMMARY Total: (parse error: {e})')
    return 0


# --- validate-theme <config_path>: Pass 1 出力から theme JSON を抽出・検証 ---
def cmd_validate_theme(argv):
    config_path = argv[0]
    tomllib = _tomllib()
    with open(config_path, 'rb') as f:
        config = tomllib.load(f)
    valid_tracks = set(config.get('tracks', {}).keys())
    expected_count = len(valid_tracks)

    if expected_count == 0:
        print('No tracks defined in config.toml', file=sys.stderr)
        return 1

    raw = sys.stdin.read().strip()

    # マークダウンコードフェンスを除去
    raw = re.sub(r'^```(?:json)?\s*', '', raw)
    raw = re.sub(r'\s*```\s*$', '', raw)

    # JSON 部分を抽出
    match = re.search(r'\{.*\}', raw, re.DOTALL)
    if not match:
        print('No JSON object found', file=sys.stderr)
        return 1

    try:
        d = json.loads(match.group())
    except json.JSONDecodeError as e:
        print(f'JSON parse error: {e}', file=sys.stderr)
        return 1

    themes = d.get('themes', [])
    if not isinstance(themes, list) or len(themes) != expected_count:
        print(f'Expected {expected_count} themes, got {len(themes) if isinstance(themes, list) else type(themes).__name__}', file=sys.stderr)
        return 1

    for i, t in enumerate(themes):
        for k in ('track', 'topic', 'slug', 'score', 'rationale'):
            if k not in t:
                print(f'Theme {i}: missing key "{k}"', file=sys.stderr)
                return 1
        if t['track'] not in valid_tracks:
            print(f'Theme {i}: invalid track "{t["track"]}" (valid: {sorted(valid_tracks)})', file=sys.stderr)
            return 1
        if not isinstance(t['slug'], str) or not re.fullmatch(r'[a-z0-9-]+', t['slug']):
            print(f'Theme {i}: invalid slug "{t.get("slug")}"', file=sys.stderr)
            return 1
        # topic と rationale の文字数上限（プロンプトインジェクション緩和）
        if len(str(t.get('topic', ''))) > 200:
            print(f'Theme {i}: topic too long (max 200)', file=sys.stderr)
            return 1
        if len(str(t.get('rationale', ''))) > 500:
            print(f'Theme {i}: rationale too long (max 500)', file=sys.stderr)
            return 1

    print(json.dumps(d, ensure_ascii=False))
    return 0


# --- result-field: stdin の claude -p JSON から result フィールド文字列を出力 ---
def cmd_result_field(argv):
    d = json.loads(sys.stdin.read())
    d = _result_dict(d)
    print(d.get('result', ''))
    return 0


# --- vault-path [config_path]: config.toml の [general].vault_path を出力 ---
def cmd_vault_path(argv):
    config_path = argv[0] if argv else 'config.toml'
    tomllib = _tomllib()
    with open(config_path, 'rb') as f:
        print(tomllib.load(f).get('general', {}).get('vault_path', ''))
    return 0


# --- themes-log <theme_json>: 選定テーマを 1 行ログ用に整形 ---
def cmd_themes_log(argv):
    d = json.loads(argv[0])
    themes = d.get('themes', [])
    parts = []
    for t in themes:
        parts.append(f'{t.get("track", "?")}="{t.get("topic", "?")}"')
    print('Pass 1 themes: ' + ', '.join(parts))
    return 0


# --- tracks [config_path]: config.toml の tracks から "track<TAB>target_repo" を出力 ---
def cmd_tracks(argv):
    config_path = argv[0] if argv else 'config.toml'
    tomllib = _tomllib()
    with open(config_path, 'rb') as f:
        c = tomllib.load(f)
    for track, v in c.get('tracks', {}).items():
        repo = v.get('target_repo')
        if repo:
            print(f'{track}\t{repo}')
    return 0


# --- past-themes [past_topics_path] [config_path]: track 別直近 10 件の履歴を出力 ---
def cmd_past_themes(argv):
    from collections import defaultdict
    tomllib = _tomllib()
    past_path = argv[0] if len(argv) >= 1 else 'past_topics.json'
    config_path = argv[1] if len(argv) >= 2 else 'config.toml'

    try:
        with open(past_path) as f:
            topics = json.load(f).get('topics', [])
    except (FileNotFoundError, json.JSONDecodeError):
        topics = []

    with open(config_path, 'rb') as f:
        active_tracks = set(tomllib.load(f).get('tracks', {}))

    by_track = defaultdict(list)
    for t in topics:
        if t.get('track') in active_tracks and t.get('title'):
            by_track[t['track']].append(t)

    print("=== 過去テーマ履歴 (track 別直近 10 件) ===")
    print("以下と同じテーマ・同じ主ソース (論文・プロジェクト) の再選定は禁止。")
    print("後続研究・新展開を扱う場合のみ可 (rationale に何が新展開かを明記すること)。")
    print()
    for track, items in by_track.items():
        items.sort(key=lambda t: t.get('date', ''))
        print(f"Track: {track}")
        for t in items[-10:]:
            title = t['title'][:120] + ('…' if len(t['title']) > 120 else '')
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
        print(f'graph not found: {path}', file=sys.stderr)
        return 2
    except json.JSONDecodeError as e:
        print(f'graph JSON parse error: {e}', file=sys.stderr)
        return 3
    if not isinstance(g, dict) or '@graph' not in g:
        print('graph schema invalid: missing @graph', file=sys.stderr)
        return 4
    return 0


COMMANDS = {
    'parse-stream': cmd_parse_stream,
    'error-fields': cmd_error_fields,
    'log-summary': cmd_log_summary,
    'total-summary': cmd_total_summary,
    'validate-theme': cmd_validate_theme,
    'result-field': cmd_result_field,
    'vault-path': cmd_vault_path,
    'themes-log': cmd_themes_log,
    'tracks': cmd_tracks,
    'past-themes': cmd_past_themes,
    'graph-health': cmd_graph_health,
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        print(f'usage: dr_pipeline.py <{" | ".join(COMMANDS)}> [args]', file=sys.stderr)
        return 64
    return COMMANDS[argv[0]](argv[1:])


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
