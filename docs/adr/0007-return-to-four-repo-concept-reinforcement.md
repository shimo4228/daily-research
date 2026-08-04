# ADR-0007: 自由探索 line を全廃し、4 研究 repo への 1:1 コンセプト補強構成へ回帰する

## Status

Superseded by [ADR-0008](0008-per-repo-in-context-research.md) (2026-08-04)

## Date

2026-07-31

## Context

2026-07-19 の ADR-0005 再編以降、4 ラインは repo-backed 1 本 (`agent_systems` = AKC + Contemplative Agent + AAP) + 自由探索 3 本 (`human_ai_publics` / `tech` / `software_paradigms`) で構成されていた。自由探索 line は飽和 cluster 反発によって「既に耕した領域から遠い未踏サブ領域」を機構的に選ぶ設計で、セレンディピティの担保が目的だった。

しかし運用の実感として、自由探索 3 本の出力は **ユーザーの関心から構造的に遠ざかり続けた**。cluster 反発は定義上「関心が繰り返し向かう領域 = 飽和 cluster」を選定禁止にするため、続けるほど関心ど真ん中のテーマが排除される。「関心に関係ないことをリサーチしても仕方がない」というのがユーザーの結論である。

参照した過去構成: 2026-07-07 再編（ADR-0004）直前の 4 track 構成（`config.toml.bak` に現存）は authorship / contemplative / aap / akc の 4 repo に 1:1 でマッピングされたコンセプト補強構成だった。

## Decision

1. **4 ラインを 4 つの DOI 登録済み研究 repo への 1 line = 1 repo コンセプト補強構成に戻す**: `akc` (agent-knowledge-cycle) / `contemplative` (contemplative-agent) / `aap` (agent-attribution-practice) / `authorship` (authorship-strategy)。schema は現行の `[[tracks.X.repos]]` 形式のまま（旧 schema への復帰はしない）。
2. **repo 寄与機構 (coverage / frontier モード + frontier_questions) は維持する**。graph.jsonld への日次増分記録も継続。
3. **cluster 反発は不適用にする**。`dr_pipeline.py cluster-report` に「全 line が repo-backed なら飽和 cluster リストを出力しない」ガードを追加（自由探索 line が存在する config では従来通り動作）。report-lint の cluster 違反検査はもともと `mode=explore` 限定のため変更不要。
4. **past_topics.json の履歴 dedup は aliases で継続する**: `akc` ← `agent_systems` / `agent_cognition`、`aap` ← `attribution`。廃止 line (`human_ai_publics` / `tech` / `software_paradigms`) の履歴はどの line にも写像しない。

## Alternatives Considered

- **旧テーマ時代 (tech / personal / ai_dev) への復帰** — 提示したが不採用。ユーザーの指すべき「以前」は repo コンセプト補強の頃だった。
- **現行 4 ラインの focus だけ関心寄りに書き換え** — cluster 反発が残る限り関心テーマの排除が続くため不十分。
- **cluster 反発を残したまま repo 構成に戻す** — 関心ど真ん中（contemplative 系等）が飽和 cluster として選定禁止になり続け、今回の意図と正面衝突するため不採用。
- **cluster 反発機構のコード削除** — 自由探索 line を将来復活させる可能性を閉じる。config 駆動のガードなら config だけで再有効化できるため、削除でなくガードを選んだ。

## Consequences

- レポート 4 本すべてが研究 repo の概念体系の発展に直結し、wiki-harvest 経由の repo 還元ループが 4 repo に広がる。
- Authorship Strategy が active mapping に復帰（ADR-0005 で外れていた）。`.repo-graphs/authorship.jsonld` が sync 対象に戻る。
- セレンディピティ（未踏領域の発見）の機構的担保は失われる。frontier モードの「挑戦・拡張・新 concept 候補」が新規性の主担保になる。
- `report_variant` (maker / platform_digest) は現構成では未使用（コード・テンプレートは残置。自由探索 line を復活させれば再び機能する）。
- 廃止 3 line の過去テーマ履歴は past-themes レポートに出なくなるが、past_topics.json 自体は保持され、graph.jsonld の Article 履歴も残る。
