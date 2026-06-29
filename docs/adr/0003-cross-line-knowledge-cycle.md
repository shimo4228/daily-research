# ADR-0003: daily-research を複数研究ラインにまたがる知識環流エンジンとして認識する

## Status

Accepted

## Date

2026-06-29

## Context

ADR-0001 は daily-research を個々の DOI 登録済み研究 repo に対する R&D フィードバックエンジンとして設計した。その後の継続的な運用観察によって、より広域な特性が確認された。daily-research は単一 repo を対象とした孤立システムではなく、複数の独立した研究ラインにまたがる知識環流サイクルの書き込み側として機能している。本 ADR はこの特性を設計上の認識事項として文書化するものであり、将来計画の宣言ではない。

現在 daily-research は 4 つの DOI 登録済み研究ライン — Agent Knowledge Cycle (AKC)、Agent Attribution Practice (AAP)、Contemplative Agent、authorship-strategy — を対象 track として日次運用している。daily-research は外部研究をリサーチし、その成果を共有知識基盤（shared knowledge substrate / wiki）にレポートとして書き込む。各研究ラインはその基盤を読み取り専用で参照し、見出した知見を人手で自ラインの concept graph へ取り込む。ある研究ラインが外部研究から吸収した概念が、別の研究ラインの次のリサーチインプットになりうる。このフィードバック構造は多日間の運用で観察されている現在の動作である。

各研究ラインが共有基盤に書き込むもの・読み出すものを規律するフィルターは、AKC の signal-first 原則に対応する（[AKC DOI: 10.5281/zenodo.19200726](https://doi.org/10.5281/zenodo.19200726) / [concept URI: signal-first](https://shimo4228.github.io/shimo4228/vocab#akc/concept/signal-first)）。signal-first は「次のアクションを変える情報だけを取り込む」という情報選別の原則であり、AKC ADR-0010 "Human Cognitive Resource as Central Constraint"（[AKC repo](https://github.com/shimo4228/agent-knowledge-cycle/blob/main/docs/adr/0010-human-cognitive-resource-as-central-constraint.md)）がこれを設計軸として位置付けている。daily-research の Pass 1 テーマ選定（未補強 concept 優先）は、この原則の実装形態の一つである。

共有知識基盤の物理的な置き場はオペレーター固有のプライベート環境に依存する。本 ADR はその具体的なパスや実装詳細を記録しない。公開ドキュメントでは「shared knowledge substrate / wiki」と総称する。

## Decision

1. daily-research が複数 DOI 登録済み研究ラインにまたがる知識環流サイクルの書き込み側として機能していることを、設計上認識された稼働中の特性として文書化する。

2. 共有知識基盤は公開ドキュメント上で「shared knowledge substrate / wiki」と総称し、オペレーター固有のパス・実装の詳細は記録しない。

3. daily-research から各研究ラインへの寄与フローは、ADR-0001 の read-only 参照方針と整合して一方向・人手介在のままとする。daily-research が研究 repo を直接編集することはない。

4. 各ラインが共有基盤から取り込む情報の選別基準は AKC signal-first 原則（[10.5281/zenodo.19200726](https://doi.org/10.5281/zenodo.19200726)）に準拠する。signal-first の出力側双対（フロンティア差分）は ADR-0002 で別途記録する。

## Alternatives Considered

### 研究ライン間の自動双方向同期

daily-research が複数 repo の graph を相互に自動更新する設計。repo 管理ライフサイクルへの干渉と衝突リスクが高い。ADR-0001「repo graph への daily-research 直接書き込み」棄却と同じ理由で棄却する。人手介在の一方向フローで現状の要件を満たしている。

### multi-researcher federation モデルへの拡張

ResearchTwin（arXiv:2603.00080）は研究者の publication / dataset / code をデジタルツインとして連接し、複数研究者間の federated discovery を実現するプラットフォームである。OmniScientist（arXiv:2511.16931）は human-AI 協調の多エージェント科学研究エコシステムを構成する。いずれも本設計に隣接するが、対象とするスコープが異なる。本設計は単一オペレーターが複数研究ラインを管理するという構成（n=1 観察）であり、multi-researcher federation ではない。本 ADR は外部研究との比較において新規性を主張しない。

### 共有基盤の外部 MCP / ベクトル DB への置き換え

外部 MCP 依存の静かな失敗リスク（ADR-0001「Mem0 復旧」棄却済み）を再度招く。現規模ではローカルファイルベースで十分であり、導入コストが便益を上回るため棄却する。

## Consequences

### Positive

- エコシステム全体の便益が複数研究ラインにわたって積み上がる。一つのラインが外部研究から取り込んだ概念が、他ラインのリサーチ入力になるフィードバック構造が成立する。
- 人手介在フローを維持することで、取り込み品質のコントロールが各ライン担当者に委ねられ、意図しない概念汚染が防がれる。
- 共有基盤の具体的なパスを公開ドキュメントから分離することで、オペレーター固有の情報が公開 docs に漏洩しない。
- ADR-0001、ADR-0002、AKC signal-first への cross-link によって原則の来歴が明確に追跡できる。

### Negative

- 共有基盤がオペレーター固有でプライベートなため、本 ADR 単体では第三者による検証・再現が不可能。設計の正当性は運用ログと観察実績に依存する。
- 研究ライン間の環流効果の定量計測手段が現時点で存在しない。

### Neutral / Follow-ups

- 本 ADR は ADR-0001 の read-only 参照方針を継承・拡張する。方針変更は ADR-0001 と本 ADR を同時に更新する。
- signal-first 原則の出力側双対（フロンティア差分）は ADR-0002 で別途記録する。
- AKC DOI（10.5281/zenodo.19200726）および signal-first concept URI（https://shimo4228.github.io/shimo4228/vocab#akc/concept/signal-first）を原則の来歴リンクとして本 ADR に保持する。
