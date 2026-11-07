# ADR-0004: 4 track を 3 ライン (2 repo-backed + 1 自由探索) に再編し、飽和 repo に frontier モードを導入する

## Status

Accepted → Superseded by [ADR-0007](./0007-return-to-four-repo-concept-reinforcement.md) /
[ADR-0008](./0008-per-repo-in-context-research.md) (2026-08-22 注記: 自由探索 line と
frontier モード・concept-graph 機構はいずれも retire 済み)

## Date

2026-07-07

## Context

ADR-0001 が導入した coverage-gap 駆動テーマ選定は、2026-07-07 時点で構造的に「完走」した。graph.jsonld の実測では、aap は 13/13 concept、contemplative は 11/11 concept が「厚い」(補強 3+ 回) に達し、未補強・薄い concept が存在しない。authorship も 19 concept 中 13 が厚い。gap が存在しない track では、Pass 1 は「厚い concept は新展開がある場合のみ再訪可」という制約下で毎日テーマを絞り出すことになり、レポートの新規性が低下した。ADR-0002 の Negative 節が予告していた「repo graph が静的な場合、frontier は固定されたまま」という事態である。

さらに coverage 機構には運用者の関心と逆相関する偏りが確認された。authorship track では運用者の最重要関心である `attribution-diffusion` が最多補強 (5 回) = 厚いために選定機構が構造的に**回避**し、薄い側に残った起源保全・機構系 concept (origin-claim-scope-discipline、llms-txt-convention 等) にレポートが偏った。「一番知りたい軸ほど記事が来ない」のは coverage 機構の仕様的帰結だった。

加えて運用者は、2026-05-27 に廃止した汎用 tech track の復活を希望した。スコープを絞らない無関係な領域からのセレンディピティが研究ラインに新しいアイデアをもたらすためである。ただし総ライン数は 4 未満 (理想 3) に抑えたい。旧 tech track は固定 `domains` が構造的飽和 (contemplative 系 37%) を招いて廃止された経緯があり、単純復活は同じ失敗を繰り返す。

## Decision

1. **4 track → 3 ライン再編**。config.toml の `[tracks.X]` を「ライン」とし、`[[tracks.X.repos]]` 配列で 0..N の研究 repo にマッピングする:
   - `attribution` = authorship-strategy + agent-attribution-practice (帰属・拡散・説明責任)
   - `agent_cognition` = agent-knowledge-cycle + contemplative-agent (記憶・知識サイクル・内省)
   - `tech` = repo なしの自由探索ライン
   概念的に近い repo をペア化することで、単独 track では出ない交差テーマ (attribution diffusion × accountability distribution 等) を可能にする。旧 track 名は `aliases` として保持し、past_topics.json の履歴 dedup を継続する。

2. **frontier モードの導入**。coverage-report (dr_pipeline.py に移設) が repo ごとに「未補強 + 薄い concept 数 ≤ `frontier_threshold` (default 0)」を判定し、該当 repo の選定目的を「gap 埋め (coverage)」から「concept への挑戦・矛盾・拡張、新 concept 候補の探索 (frontier)」へ自動切替する。モード判定は決定論的に code が行い、探索は LLM が行う (code-owned decision + LLM execution)。coverage-report の判定と Pass 1 の宣言 mode の一致は**強制しない** — repo が朝 concept を追加した等の正当なズレで validation が硬直するのを避け、Pass 1 に裁量を残す。

3. **frontier_questions の導入**。config.toml の repo 定義に常設の未解決の問い (例: authorship「LLM-mediated diffusion の実証・測定・新チャネル」) を記述できる。frontier モードでは最優先の探索軸、coverage モードでは副次ガイドとして Pass 1 に注入される。これにより運用者の関心軸を coverage 統計と無関係に直接指定できる — attribution-diffusion 回避問題の直接の解である。

4. **graph.jsonld に `challenges` / `extends` / `mode` を追加**。frontier モードの成果は「補強」ではないため、Article ノードに挑戦・拡張の関係を別フィールドで記録する。**厚い/薄い/未補強の分類は reinforces のみ**で数え (挑戦は補強でない)、**既出表示と主ソース重複禁止 dedup は reinforces ∪ challenges ∪ extends の union** で数える。`contributesToRepo` は line 名でなく repo key 配列になる。

5. **自由探索ラインの cluster 反発**。dr_pipeline.py の `cluster-report` が graph.jsonld 全 Article の subCluster 頻度を集計し、「全期間 top-N (default 15) ∪ 直近 90 日 3 回以上」を飽和 cluster として Pass 1 に注入、選定禁止とする。旧 tech track の失敗 (固定 domains → 構造的飽和) を、既出領域への機構的な反発で再発防止する。旧 tech の過去テーマ dedup の実効層はこの cluster 反発が担う (直近 10 件表示には古い旧 tech テーマはほぼ出ないため)。

6. **旧 schema 検出 guard**。config.toml は gitignore されており、コード更新と config 移行が分離する。`tracks.X` 直下に `target_repo` を検出したら dr_pipeline.py が明示エラーを返し、「コードは新 schema・config は旧 schema」のまま朝の実行が静かに全滅する事故を防ぐ。

## Alternatives Considered

### 4 track 維持 + 日次ローテーション (1 日 2 track + tech)

schema 変更が不要で最も軽い。しかし飽和も diffusion 偏りも解決せず、交差テーマも生まれない。本数を減らすだけで新規性問題の根因に触れないため棄却。

### challenges / extends を reinforces に統一

graph schema 変更が不要になる。しかし (a)「挑戦」を「補強」として記録するのは意味論が壊れる、(b) repo が新 concept を追加して coverage モードに戻ったとき、挑戦の記録が補強回数を水増しして統計を汚染する、(c) 人間の取り込みループ (wiki-harvest) で補強と反証・拡張の区別が失われる。棄却。

### coverage-report の mode 判定と Pass 1 宣言 mode の一致強制

validation を厳格にできるが、repo graph の朝の更新・境界値付近の揺れで正当なズレが起こり、validation 硬直 → Sonnet フォールバック多発のコストが上回る。推奨モードの注入 + 緩い enum 検証に留める。

### tech ラインの新規性担保をプロンプト指示のみで行う

実装は軽いが、旧 tech track も「past_topics.json に類似テーマがない」を Novelty 基準としながら飽和した実績がある。確率的な指示遵守でなく、graph.jsonld の cluster 統計という決定論的な反発リストを注入する (構造的性質は code が担う)。

## Consequences

### Positive

- 飽和した repo でもテーマ選定の目的関数が明確 (挑戦・拡張・新 concept 候補) になり、「厚い concept の薄い新展開探し」の量産が止まる
- 運用者の関心軸 (diffusion 等) を frontier_questions で直接注入でき、coverage 統計との逆相関が解消する
- 交差テーマにより 2 repo の概念体系を橋渡しする種類の新規性が生まれる (ADR-0003 の知識環流を単一レポート内で駆動する形)
- 自由探索ラインが cluster 反発つきで復活し、セレンディピティの供給源が戻る
- レポート数が 4 → 3 本/日に減り、人間の読む負荷が下がる (AKC ADR-0010 の Human Cognitive Resource 制約と整合)

### Negative

- frontier モードの成果 (挑戦・拡張) は coverage のような「未補強 → 補強済み」という完了状態を持たず、飽和の再判定が起きない。frontier が枯れたかどうかの検出は将来課題
- Sonnet 一括フォールバック経路には coverage/cluster レポートが注入されないため、フォールバック時は frontier/反発が効かない (従来から同型の劣化があり、低頻度のため許容)
- config schema が 2 階層になり、設定の記述量が増えた

### Neutral / Follow-ups

- 既存 graph.jsonld の旧 track 名 Article は無変更で正しい (coverage 集計は concept @id のグローバル集計、cluster 集計は track 不問)
- config.toml の移行はコード更新と別の手作業。旧 schema guard がエラーで検出する。移行手順: `cp config.toml config.toml.bak` → config.example.toml を参照して書き換え
- 頻度・閾値 (`frontier_threshold` / `saturated_top_n` 等) は `[coverage]` セクションで調整可能
