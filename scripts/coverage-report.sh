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

def norm_cid(cid):
    # fragment 正規化: concept @id の "#" 以降を照合キーにする。
    # repo concept は完全 URI (https://...#concept/foo)、Pass の reinforces は
    # fragment (concept/foo) で記録されるため、# 以降で揃える。# がなければ全体。
    return cid.split('#', 1)[1] if '#' in cid else cid

# daily-research graph の reinforces 履歴: 正規化 concept キー -> [(datePublished, article name), ...]
reinforced = {}
try:
    with open('graph.jsonld') as f:
        dg = json.load(f)
    for n in dg.get('@graph', []):
        if n.get('@type') == 'Article':
            d = n.get('datePublished', '')
            name = n.get('name', n.get('@id', ''))
            for cid in n.get('reinforces', []):
                reinforced.setdefault(norm_cid(cid), []).append((d, name))
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
print("各 concept の『既出:』はその concept を補強した過去レポート。同じ外部研究 (論文・")
print("プロジェクト) を主ソースとする再補強は禁止 (別 concept 宛てでも不可)。")
print()

def trunc(s, n=72):
    return s if len(s) <= n else s[:n] + '…'

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
        hits = sorted(reinforced.get(norm_cid(cid), []))
        cnt = len(hits)
        if cnt == 0:
            unc.append([f"{name}  [{cid}]"])
        elif cnt <= 2:
            lines = [f"{name} (補強 {cnt} 回, 最終 {hits[-1][0]})  [{cid}]"]
            lines += [f"    既出: {d} {trunc(t)}" for d, t in hits]
            thin.append(lines)
        else:
            lines = [f"{name} (補強 {cnt} 回)"]
            lines += [f"    既出: {d} {trunc(t)}" for d, t in hits[-3:]]
            thick.append(lines)

    for label, group in [("未補強 (0 件) — 最優先:", unc),
                         ("薄い (1-2 件):", thin),
                         ("厚い (3+ 件) — 再訪は新展開時のみ:", thick)]:
        if group:
            print(f"  {label}")
            for lines in group:
                print(f"    - {lines[0]}")
                for ln in lines[1:]:
                    print(f"  {ln}")

    # repo が既に取り込んだ外部文献 (ExternalReference)。
    # これらを主ソースとするテーマは選定禁止 (repo にとって新規性がない)。
    refs = [n for n in rg.get('@graph', []) if has_type(n, 'ExternalReference')]
    if refs:
        print(f"  repo 取り込み済み外部文献 ({len(refs)} 件) — これらを主ソースとするテーマは選定禁止:")
        for r in refs:
            rname = r.get('name', '')
            rid = r.get('@id', '')
            url = rid if rid.startswith('http') and 'vocab#' not in rid else (r.get('url') or '')
            suffix = f"  [{url}]" if url else ""
            print(f"    - {trunc(rname, 80)}{suffix}")
    print()
PYEOF
