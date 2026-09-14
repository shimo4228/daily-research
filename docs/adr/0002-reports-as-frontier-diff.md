# ADR-0002: signal-first 原則の出力側双対 — レポートをフロンティア差分として定義する

## Status

Accepted

## Date

2026-06-29

## Context

daily-research は各研究 repo の concept graph に紐づく日次リサーチレポートを生成する。[ADR-0001](./0001-research-repo-feedback-engine.md) が導入した coverage-driven theme selection は、AKC の signal-first 原則（[AKC DOI: 10.5281/zenodo.19200726](https://doi.org/10.5281/zenodo.19200726) / [concept URI: signal-first](https://shimo4228.github.io/shimo4228/vocab#akc/concept/signal-first)）の INTAKE 側実装である。`coverage-report.sh` が研究 repo graph の全 concept `@id` から `graph.jsonld` の `reinforces` 済み concept `@id` を差し引いた「未補強 concept 集合」を算出し、Pass 1 はその集合を優先的に補強する外部研究テーマを選ぶ（README "Concept coverage drives the search" 節参照）。

OUTPUT 側の対称性は同じ仕組みで実装されていながら、設計判断として明文化されていなかった。日次レポートの関連性はそれ単体の情報量ではなく、各 track が指す研究 repo の現在の concept frontier に対する差分によって条件づけられる。この出力側原則を本 ADR では「フロンティア差分」と呼ぶ。信号を先に定義し、行動を変えない情報は取り込まないという signal-first を OUTPUT 側に適用した形態である。

基底原則は AKC ADR-0010 "Human Cognitive Resource as Central Constraint"（[AKC repo](https://github.com/shimo4228/agent-knowledge-cycle/blob/main/docs/adr/0010-human-cognitive-resource-as-central-constraint.md)）が包含する。対応するコードは ADR-0001 の実装時点（2026-05-27、コミット `a506add`）に既に存在し、本記録はコード変更を伴わない。

## Decision

1. daily-research のレポート関連性を **フロンティア差分** として定義する。「フロンティア差分」とは、研究 repo graph に宣言された全 concept `@id` のうち `graph.jsonld` の `reinforces` にまだ記録されていない未補強 concept の集合に対する、レポートの補強差分である。これは signal-first の出力側適用であり、新たな概念の導入ではない。

2. 既存の coverage-driven theme selection を OUTPUT 側 signal-first の実装として記録する。README "Concept Coverage Engine" 節が記述する通り:
   - `coverage-report.sh` が「repo graph の全 concept `@id` − `graph.jsonld` の `reinforces` 済み concept `@id`」= 未補強 concept を算出する。
   - Pass 1 はこの未補強 concept を補強する最新外部研究を優先選択する。
   - Pass 2 は補強した concept を `graph.jsonld` に `reinforces` として記録し、次回実行時の frontier を前進させる。
   この三段構造がフロンティア差分の実装である。

3. AKC の signal-first 原則への由来関係を一方向 cross-link として記録する。
   - [AKC DOI: 10.5281/zenodo.19200726](https://doi.org/10.5281/zenodo.19200726)
   - [concept URI: signal-first](https://shimo4228.github.io/shimo4228/vocab#akc/concept/signal-first)
   - 上位 ADR: AKC ADR-0010 "Human Cognitive Resource as Central Constraint"

   daily-research → AKC の一方向参照のみとする。AKC の内部設計は daily-research に持ち込まない。

## Alternatives Considered

### AKC ADR-0010 への全委譲

AKC ADR-0010 "Human Cognitive Resource as Central Constraint" が signal-first の基底原則を記述しており、daily-research 側に別途 ADR を書かない選択肢もある。ただし `coverage-report.sh` による出力側 instantiation の具体的な仕組みは daily-research に固有であり、AKC 側に記述すべき粒度ではない。本 ADR を書くことで daily-research の設計判断を AKC の原則への由来として追跡可能にする。

### 近接先行研究 (gap 駆動グラフ探索 / delta ベース知識ベース構築 / KG-RAG)

gap 駆動の知識グラフ探索と delta ベースの知識ベース構築は既存研究で取り組まれており、daily-research のアプローチは独立した先行研究と重なる部分を持つ。本 ADR は外部研究との比較において新規性を主張しない。DualGraph（arXiv:2602.13830）は Outline Graph と Knowledge Graph を分離しつつ両者を統合的に分析する深層リサーチフレームワークであり、グラフ差分を探索に活用する着想は類似するが daily-research の問題設定（研究 repo への継続的 R&D フィードバック）とは直接一致しない。DeepDive（CACM 2017, DOI: 10.1145/3060586; arXiv:1502.00731）は宣言的知識ベース増分構築フレームワークであり、増分更新の発想は共通するが daily-research は専用 DB ではなく schema.org JSON-LD ファイルを基盤とし用途が異なる。GraphRAG（arXiv:2404.16130）は知識グラフを活用したクエリ焦点型要約アプローチ、HippoRAG（arXiv:2405.14831）は神経科学にインスパイアされた長期記憶 KG-RAG アプローチ（NeurIPS 2024）であり、いずれも KG-RAG の先行研究として実在するが coverage gap 駆動テーマ選定という目的とは異なる。

## Consequences

### Positive

- テーマ選定とレポート評価が同一のフィルタ（未補強 concept 集合）を共有し、INTAKE 側と OUTPUT 側の一貫性が保たれる。
- `graph.jsonld` が成長するにつれ frontier が前進し、ドメイン狭隘化が構造的に防がれる（ADR-0001 と同じメカニズム）。
- AKC ADR-0010 への one-way cross-link により、daily-research の設計判断の由来が追跡可能になる。
- コード変更を伴わない記録であり、既存の動作を壊さない。

### Negative

- フロンティア差分の品質は各 repo graph の concept 定義の整備状況に依存する。repo graph の粒度が粗い場合、未補強 concept 集合も意味的に粗くなる。
- 研究関心の広がりは repo graph の更新を通じてのみ frontier に反映される。repo graph が静的な場合、frontier は固定されたままとなる。

### Neutral / Follow-ups

- 実装の根拠は [ADR-0001](./0001-research-repo-feedback-engine.md)（2026-05-27）にある。
- signal-first の INTAKE 側（Pass 1 テーマ選定）と OUTPUT 側（フロンティア差分）の双対構造を本 ADR が明文化する。他の AKC 概念のインポートは行わない。
- daily-research が複数研究ラインにまたがる知識環流サイクルの書き込み側として機能している特性は [ADR-0003](./0003-cross-line-knowledge-cycle.md) で別途記録する。
