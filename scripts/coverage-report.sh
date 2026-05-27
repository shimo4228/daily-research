#!/usr/bin/env bash
# coverage-report.sh
# 各 repo graph (.repo-graphs/<track>.jsonld) の concept @id と、
# daily-research graph (graph.jsonld) の Article.reinforces 履歴を突き合わせ、
# 「未補強 / 薄い / 厚い」concept を track 別に出力する。
#
# 出力は Pass 1 (theme-selection) の prompt に concat され、
# 未補強 concept を優先補強するテーマ選定を駆動する。
# stdout に report を出すだけ (副作用なし)。Pass 1 前に daily-research.sh が呼ぶ。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

python3 <<'PYEOF'
import json, os, tomllib
from datetime import date

# daily-research graph の reinforces 履歴: concept @id -> [datePublished, ...]
reinforced = {}
try:
    with open('graph.jsonld') as f:
        dg = json.load(f)
    for n in dg.get('@graph', []):
        if n.get('@type') == 'Article':
            d = n.get('datePublished', '')
            for cid in n.get('reinforces', []):
                reinforced.setdefault(cid, []).append(d)
except FileNotFoundError:
    pass

def has_type(n, t):
    typ = n.get('@type')
    return t == typ or (isinstance(typ, list) and t in typ)

with open('config.toml', 'rb') as f:
    cfg = tomllib.load(f)

today = date.today().isoformat()
print(f"=== Concept coverage report (as of {today}) ===")
print("各 repo の concept を補強回数で分類。Pass 1 は『未補強』『薄い』concept を")
print("優先的に補強する外部研究テーマを選ぶこと (厚い concept の再訪は新展開がある時のみ)。")
print()

for track, v in cfg.get('tracks', {}).items():
    graph_path = v.get('target_graph', f'.repo-graphs/{track}.jsonld')
    repo_name = (v.get('target_repo', '') or '').rstrip('/').split('/')[-1]
    if not os.path.exists(graph_path):
        print(f"Track: {track}  (repo graph not synced: {graph_path})")
        print()
        continue
    with open(graph_path) as f:
        rg = json.load(f)
    concepts = [n for n in rg.get('@graph', []) if has_type(n, 'Concept')]
    print(f"Track: {track}  (repo: {repo_name}, {len(concepts)} concepts)")

    unc, thin, thick = [], [], []
    for c in concepts:
        cid = c.get('@id')
        name = c.get('name', cid)
        hits = reinforced.get(cid, [])
        cnt = len(hits)
        if cnt == 0:
            unc.append(f"{name}  [{cid}]")
        elif cnt <= 2:
            thin.append(f"{name} (補強 {cnt} 回, 最終 {max(hits)})  [{cid}]")
        else:
            thick.append(f"{name} (補強 {cnt} 回)")

    if unc:
        print(f"  未補強 (0 件) — 最優先:")
        for it in unc:
            print(f"    - {it}")
    if thin:
        print(f"  薄い (1-2 件):")
        for it in thin:
            print(f"    - {it}")
    if thick:
        print(f"  厚い (3+ 件) — 再訪は新展開時のみ:")
        for it in thick:
            print(f"    - {it}")
    print()
PYEOF
