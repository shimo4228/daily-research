# ADR-0001: daily-research を汎用トレンドリサーチから 3 研究 repo の R&D フィードバックエンジンへ転換

## Status

Accepted

## Date

2026-05-27

## Context

daily-research は毎朝 launchd で `claude -p` を 2 パス (Opus テーマ選定 → Sonnet リサーチ・執筆) 実行し、Obsidian vault にレポートを保存する自律システムである。

従来の設計では汎用トレンド 3 トラック (tech / personal / ai_dev) を用い、各トラックに固定 domains を設定していた。たとえば personal トラックの domains は「瞑想 / FEP / 能動的推論」であった。

実データ計測によって構造的飽和が判明した。`past_topics.json` 238 件中、contemplative 系テーマが 88 件 (37%) を占め、personal トラック直近 30 日はほぼ全件が「meditation × neuroscience × predictive processing」に集中していた。固定 domains がドメイン狭隘化を招き、同一概念のテーマが繰り返し選定されていた。飽和の根本原因は固定 domains にあり、重複警告のような対症療法では解決しない。

この転換の直前に 2 つの判断が実施済みである。(1) Mem0 Cloud MCP を撤去した。2026-02-26 に main へマージしたが `.mcp.json` 不在とヘルスチェック形骸化により 32 日間ゼロ稼働し、外部 MCP 依存の静かな失敗リスクが顕在化した。(2) 後継の永続メモリ層として、ローカル JSON-LD concept cluster graph (`graph.jsonld`) を導入した。

ユーザーは 3 つの DOI 登録済み idea-rescue 研究 repo (authorship-strategy, contemplative-agent, agent-attribution-practice) を運用している。daily-research をこれらの repo の概念体系の発展に直接寄与させる R&D フィードバックループを構築することが求められた。

## Decision

1. 各 track を 1 つの DOI 登録済み研究 repo にマッピングする。

   | track | repo | Zenodo DOI |
   |-------|------|------------|
   | authorship | authorship-strategy | zenodo.20263316 |
   | contemplative | contemplative-agent | zenodo.19212118 |
   | aap | agent-attribution-practice | zenodo.19652013 |

2. 固定 domains を廃止し、関心領域を各 repo の `graph.jsonld` (schema.org JSON-LD で Concept / ADR / Axiom 等を表現) から動的に決定する。

3. concept coverage gap 駆動のテーマ選定を導入する。起動時に各 repo graph を `.repo-graphs/<track>.jsonld` へ sync し、`coverage-report.sh` が「repo の全 concept `@id` − daily-research graph の `reinforces` 済み concept `@id`」= 未補強 concept を算出する。Pass 1 はこの未補強 concept を最優先で補強する最新外部研究をテーマに選ぶ。

4. Pass 2 はレポート末尾に「この repo への寄与」節を設け、補強した concept `@id` を `graph.jsonld` の Article に `reinforces` として記録する。

5. repo は read-only 参照のみとする。寄与は vault レポート経由で人間が手動で取り込み、daily-research が repo を直接編集することはない。

6. 旧 Phase 3 の subCluster 飽和警告は coverage report に発展的に吸収し、単独実装しない。

## Alternatives Considered

### Mem0 復旧

32 日間ゼロ稼働の実績に加え、Mem0 公式が HTTP transport (`https://mcp.mem0.ai/mcp/`) へ完全移行し旧 npm パッケージが deprecated、ツール名もハイフン→アンダースコアに破壊的変更された。再復旧コストが撤去コストを上回るため棄却。外部 MCP 依存の静かな失敗リスクも残る。

### ベクトル化 (embedding + cosine 類似度で重複検出)

238 concept 規模では Opus 1M context に全件が収まり、LLM 自身の概念判定が embedding cosine より適切である。集合演算 (concept `@id` の差分) で十分なため棄却。1000 件超になった時点で再検討する。

### 汎用トレンド track 存続 + subCluster 飽和警告のみ追加

固定 domains のドメイン狭隘化が飽和の根本原因であり、飽和警告は対症療法にすぎない。repo マッピングで根治できるため棄却。

### repo graph への daily-research 直接書き込み

別 repo の管理ライフサイクルへの干渉と repo 汚染リスクがある。read-only 参照 + vault 経由の人間取り込みが安全なため棄却。

### repo graph 読み込みを `--add-dir` で許可

起動時に `cp` で cwd 内 `.repo-graphs/` へ sync する方が `allowedTools` 変更不要で権限リスクが低く、既存の `past_topics.json` バックアップ `cp` パターンと整合するため棄却。

## Consequences

### Positive

- 未補強 concept を優先するため、同じ概念のテーマが繰り返されるドメイン狭隘化が構造的に防がれる。
- 3 つの DOI 研究 repo の概念体系の発展に daily-research が直接寄与する R&D フィードバックループが成立する。
- 外部 MCP 依存ゼロ。`graph.jsonld` はローカルファイルであり「ファイルが存在する = 動作する」が自明で、静かな失敗が起きない。
- schema.org 準拠の graph により将来の LLM 引用・公開にも適性がある。

### Negative

- repo graph の鮮度依存: 古い repo graph を読むと誤誘導が生じる。各 repo の graph 更新は別管理 (release-doi / 手動) であり、daily-research は読むだけで制御できない。
- Pass 1 のコンテキスト増: 3 repo graph + coverage report の追加により、Opus 1M context では問題ないがトークンが微増する。
- `config.toml` の track 名と Pass 1 prompt の track 名が密結合している。track 名変更時は config と prompt を同時更新しないと validation が壊れフォールバックする。

### Neutral / Follow-ups

- 既存 `graph.jsonld` の 250 articles は履歴として残す。新 Article から `contributesToRepo` / `reinforces` を記録し、遡及付与はしない。
- README (en/ja) の全面改訂が別途必要 (本 ADR の範囲外、別タスク)。
- 実装コミット: `a506add` (2026-05-27)。Pass 1/2 の E2E は翌朝 launchd 実行で検証予定。
