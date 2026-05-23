# graph.jsonld スキーマ仕様

> daily-research の永続メモリ層 (Mem0 撤去後の後継)。
> schema.org 準拠の JSON-LD で、過去レポートを concept cluster に紐づけて
> Pass 1 のテーマ選定に飽和警告を注入することが目的。

## 目的

1. **概念飽和の機械的可視化** — 直近 30/90/180 日の subCluster カウントを集計し、Pass 1 に「飽和」「休眠」「不活発」をシグナルとして渡す
2. **連続性 narrative の素材** — 同一 subCluster の過去レポートを Pass 2 が参照できる土台 (将来の B2 拡張用)
3. **schema.org 引用適性** — 標準語彙 (`Article` `Thing` `about` `datePublished`) を優先することで、将来 graph をそのまま公開・引用される可能性を残す

## 全体構造

```jsonld
{
  "@context": {
    "@vocab": "https://schema.org/",
    "dr": "https://github.com/shimo4228/daily-research/ns#",
    "broadCluster": "dr:broadCluster",
    "subCluster": "dr:subCluster",
    "track": "dr:track",
    "broaderClusterOf": "dr:broaderClusterOf"
  },
  "@graph": [
    { "@type": "Article", ... },
    { "@type": "Thing", ... }
  ]
}
```

## ノード型

### `@type: "Article"` (各レポート 1 件 = 1 ノード)

| プロパティ | 必須 | 説明 |
|---|---|---|
| `@id` | ✅ | `dr:topic/{YYYY-MM-DD}_{track}_{slug}` |
| `name` | ✅ | topic のタイトル (日本語可) |
| `datePublished` | ✅ | `YYYY-MM-DD` |
| `track` | ✅ | `tech` / `personal` / `ai_dev` (config.toml に準拠) |
| `broadCluster` | ✅ | `dr:cluster/{broad_name}` を 1 件指定 |
| `subCluster` | ✅ | `dr:cluster/{sub_name}` の配列 (1 件以上、複数許可) |
| `about` | 任意 | Wikidata `@id` または `dr:concept/...` 配列。意味タグ |

### `@type: "Thing"` (各 cluster 1 件 = 1 ノード)

| プロパティ | 必須 | 説明 |
|---|---|---|
| `@id` | ✅ | `dr:cluster/{name}` |
| `name` | ✅ | 人間可読な cluster 名 (英語 + 日本語併記可) |
| `broaderClusterOf` | subCluster の場合 ✅ | 親 broadCluster の `@id` |

## Cluster Naming Convention

- **形式**: lowercase + underscore、30 文字以内
- **命名**: 概念領域を表す名詞句 (動詞・形容詞ではなく)
- **重複禁止**: 同一意味の cluster は統合 (例: `meditation_neuroscience` と `meditation_neuroimaging` のどちらか一方)

### broadCluster 候補 (6-8 個目安、過剰増殖禁止)

bootstrap 時に Opus が past_topics.json 全体を見て決定する。参考例:

- `contemplative_meditation_science` — 瞑想 × 神経科学 × 意識
- `ai_governance_policy` — AI 規制・標準化・著者権
- `claude_code_ecosystem` — Claude Code 周辺ツール・skills・MCP
- `llm_evaluation_benchmarking` — モデル評価・leaderboard・benchmark
- `embodied_cognition_ai` — 身体性認知・active inference の AI 応用
- `agent_infrastructure` — エージェント基盤・autonomy・runtime
- `ai_developer_strategy` — AI 時代の開発者戦略・workflow 変容
- `b2a_standards` — llms.txt / MCP / Agent Skills 等 B2A プロトコル

### subCluster 命名規則

- broadCluster より具体的な粒度 (例: `predictive_processing_meditation`、`meditation_radar_chart_framework`)
- 同一 broadCluster 配下に複数 subCluster が並ぶことを前提
- 1 article に複数 subCluster を割り当ててよい (典型的な交差概念のため)

## 例: 完全なノード 2 件

```jsonld
{
  "@id": "dr:topic/2026-05-22_personal_lieberman-sacchet-2026-multidimensional-consciousness-meditation",
  "@type": "Article",
  "name": "Lieberman & Sacchet 2026『Toward a Neuroscience of Consciousness Using Advanced Meditation』",
  "datePublished": "2026-05-22",
  "track": "personal",
  "broadCluster": "dr:cluster/contemplative_meditation_science",
  "subCluster": [
    "dr:cluster/consciousness_phenomenology_advanced_meditation",
    "dr:cluster/meditation_radar_chart_framework"
  ]
}
,
{
  "@id": "dr:cluster/predictive_processing_meditation",
  "@type": "Thing",
  "name": "Predictive processing × meditation",
  "broaderClusterOf": "dr:cluster/contemplative_meditation_science"
}
```

## 整合性ルール (検証スクリプトでチェック)

1. すべての Article の `broadCluster` 値が、`@type: "Thing"` ノードの `@id` に存在する
2. すべての Article の `subCluster` 配列内 `@id` が、`@type: "Thing"` ノードの `@id` に存在する
3. すべての subCluster (broaderClusterOf を持つ Thing) の親 broadCluster が、`@type: "Thing"` ノードの `@id` に存在する
4. broadCluster の数は 6-8 個の範囲 (目安。10 を超えたら taxonomy 設計を再考)
5. `datePublished` は `YYYY-MM-DD` 形式

## 出力ファイル配置

- `graph.jsonld` — プロジェクトルート、git 管理 (個人データではなく cluster 構造)
- `graph.jsonld.bak` — Pass 2 実行前バックアップ (gitignore)

## 関連プラン

- `~/.claude/plans/cosmic-dazzling-fox.md` — 全体プラン (Phase 1-5)
