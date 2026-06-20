#!/usr/bin/env bash
# bootstrap-graph.sh
# past_topics.json (238 topics) を Opus で concept cluster に分類し、
# graph.jsonld をワンショットで生成する。
#
# 用途: 初回 bootstrap のみ。日次運用は daily-research.sh が Pass 2 末尾で増分更新。
# 注意: Claude Code セッション内ターミナルで実行するとネストエラーになる。
#       必ず別ターミナルから実行すること。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

LIB_DIR="$PROJECT_DIR/scripts/lib"
# shellcheck disable=SC2034  # DR_PY は source した lib/auth.sh で使用
DR_PY="$LIB_DIR/dr_pipeline.py"

LOG_FILE="$PROJECT_DIR/logs/bootstrap-graph-$(date +%Y-%m-%d).log"
mkdir -p "$PROJECT_DIR/logs"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# 環境サニタイズ + PATH + 実 auth probe を lib から取得 (daily-research.sh と共有)
source "$LIB_DIR/env.sh"
source "$LIB_DIR/auth.sh"

log "=== bootstrap-graph: 開始 ==="

# 既存 graph.jsonld のバックアップ
if [ -f "$PROJECT_DIR/graph.jsonld" ]; then
  cp "$PROJECT_DIR/graph.jsonld" "$PROJECT_DIR/graph.jsonld.bak"
  log "Backed up existing graph.jsonld → graph.jsonld.bak"
fi

# claude 存在確認
if ! command -v claude >/dev/null 2>&1; then
  log "ERROR: claude not found in PATH"
  exit 1
fi
CLAUDE_CMD=$(command -v claude)
log "Using claude: $CLAUDE_CMD"

# 認証確認 (実 auth probe。--version は OAuth 期限切れを検出できないため使わない)
if ! real_auth_probe; then
  log "ERROR: Claude authentication expired. Run 'claude' interactively first."
  exit 1
fi

# bootstrap prompt
BOOTSTRAP_PROMPT='past_topics.json (238 topics) を読み込み、docs/graph-schema.md のスキーマに従って graph.jsonld を生成してください。

手順:
1. Read で docs/graph-schema.md を読み、スキーマ規約を把握する
2. Read で past_topics.json を読み、全 238 topics を確認する
3. broadCluster taxonomy を 6-8 個決定する (docs/graph-schema.md の例を参考、過去 topic 全体を見て調整)
4. 各 topic について broadCluster 1 件 + subCluster 1-3 件を割り当てる
5. Write で graph.jsonld を生成する (プロジェクトルート、絶対パスは使わず相対パス graph.jsonld)

重要な制約:
- 出力 JSON は valid JSON-LD (parser でエラーにならない構造)
- すべての Article の broadCluster / subCluster は @graph 内の Thing として @id 定義済みであること
- すべての subCluster (broaderClusterOf を持つ Thing) の親 broadCluster が @graph 内に存在すること
- broadCluster は 6-8 個に収める (過剰増殖禁止)
- 同一意味の cluster は統合する (例: meditation_neuro と meditation_neuroimaging を分けない)
- 各 Article の @id は dr:topic/{YYYY-MM-DD}_{track}_{slug} 形式
- slug は past_topics.json の英語 slug を使用
- 完了後、生成内容を 5 行以内で要約報告すること (broadCluster 名一覧と最大カウント subCluster を含む)'

log "Running Opus bootstrap (max-turns=10, model=opus, allowedTools=Read,Write)..."
BOOTSTRAP_EXIT=0
BOOTSTRAP_OUT=$(< /dev/null "$CLAUDE_CMD" -p "$BOOTSTRAP_PROMPT" \
  --permission-mode default \
  --allowedTools "Read,Write" \
  --max-turns 10 \
  --model opus \
  --output-format json \
  --no-session-persistence \
  2>> "$LOG_FILE") || BOOTSTRAP_EXIT=$?

# 出力ログ (cost / tokens / summary を保存)
if [ -n "$BOOTSTRAP_OUT" ]; then
  echo "$BOOTSTRAP_OUT" >> "$LOG_FILE"
  # Result text 抽出 (Opus の要約)
  SUMMARY=$(echo "$BOOTSTRAP_OUT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('result', '')[:500])
except Exception as e:
    print(f'(parse error: {e})')
" 2>> "$LOG_FILE") || true
  if [ -n "$SUMMARY" ]; then
    log "Opus summary:"
    echo "$SUMMARY" | tee -a "$LOG_FILE"
  fi
fi

if [ $BOOTSTRAP_EXIT -ne 0 ]; then
  log "ERROR: Opus bootstrap failed (exit=$BOOTSTRAP_EXIT)"
  exit 1
fi

# graph.jsonld 存在確認
if [ ! -f "$PROJECT_DIR/graph.jsonld" ]; then
  log "ERROR: graph.jsonld was not created by Opus"
  exit 1
fi

# 構造検証 (スキーマ整合性 + 件数チェック)
log "Validating graph.jsonld structure..."
VALIDATE_OUT=$(python3 - <<'PYEOF' 2>&1
import json, sys

with open('graph.jsonld') as f:
    g = json.load(f)

assert '@context' in g, '@context missing'
assert '@graph' in g, '@graph missing'

articles = [n for n in g['@graph'] if n.get('@type') == 'Article']
things = [n for n in g['@graph'] if n.get('@type') == 'Thing']

print(f'Articles: {len(articles)}')
print(f'Things (clusters): {len(things)}')

if len(articles) != 238:
    print(f'WARN: Expected 238 Articles, got {len(articles)}', file=sys.stderr)
    sys.exit(2)

broad = [t for t in things if 'broaderClusterOf' not in t]
sub = [t for t in things if 'broaderClusterOf' in t]
print(f'broadClusters: {len(broad)} | subClusters: {len(sub)}')

if not (6 <= len(broad) <= 10):
    print(f'WARN: broadCluster count out of range [6,10]: {len(broad)}', file=sys.stderr)
    sys.exit(2)

# ID 整合性
ids = {n['@id'] for n in g['@graph']}
missing = []
for a in articles:
    bc = a.get('broadCluster')
    if bc and bc not in ids:
        missing.append(f"Article {a['@id']} broadCluster={bc}")
    for sc in a.get('subCluster', []):
        if sc not in ids:
            missing.append(f"Article {a['@id']} subCluster={sc}")
for s in sub:
    parent = s.get('broaderClusterOf')
    if parent not in ids:
        missing.append(f"Thing {s['@id']} broaderClusterOf={parent}")

if missing:
    print('ERROR: dangling references:', file=sys.stderr)
    for m in missing[:10]:
        print(f'  {m}', file=sys.stderr)
    sys.exit(2)

# broadCluster 名一覧
print('broadCluster names:')
for b in broad:
    art_count = sum(1 for a in articles if a.get('broadCluster') == b['@id'])
    print(f"  {b['@id']:60} ({art_count} articles)")

print('Validation passed')
PYEOF
) || VALIDATE_EXIT=$?

echo "$VALIDATE_OUT" | tee -a "$LOG_FILE"

if [ "${VALIDATE_EXIT:-0}" -ne 0 ]; then
  log "ERROR: graph.jsonld validation failed (exit=${VALIDATE_EXIT})"
  log "Hint: review $LOG_FILE and fix graph.jsonld or rerun bootstrap"
  exit 2
fi

log "=== bootstrap-graph: 完了 ==="
log "graph.jsonld is ready. Next step: schedule daily-research.sh tomorrow and confirm Pass 2 increments graph correctly."
