# ADR-0013: edge line (AI 活用の限界突破事例) を daily で新設する

## Status

Accepted (ADR-0011 決定 1〜4 の daily 機構を再使用。ADR-0012 決定 2 が想定した「速い line が現れたら再利用する」の初適用 — supersede ではない)

## Date

2026-08-20

## Context

2026-08-20、運用者は「AI 活用をやりすぎて限界突破している事例」を毎日レポートする新研究ラインを指示した。趣旨は「スーパーエッジケースの中こそ学ぶべきことがある」— AI 活用の分布の端 (常識外の規模・手法での成功、やりすぎの果ての崩壊、生活・認知の全面 AI 委譲) には、平均的活用からは観測できない学びが先に現れるという仮説の検証。観測範囲は運用者確認により 3 本柱: 突破系 (成功エッジ) / 崩壊系 (失敗エッジ・post-mortem) / 生活・認知系エッジ。

アーキテクチャ (ADR-0008) 上、line は cwd となる接地 repo を要する。desire line の先例 (ADR-0011) に倣い、最小の資料中心 repo を新設する方針を運用者が選択した。

エッジ事例の出現は HN / Reddit / X / 個人ブログ等で日単位に流れるイベントであり、6〜7 日周期の輪番では捕捉が遅れる。daily 機構 (ADR-0011 決定 1〜4: schema / per-line ループ / E_PARTIAL / metrics 合算) は ADR-0012 以降使用 line なしで温存されている。

## Decision

1. **track `edge` を新設し `daily = true` とする**。接地 repo は `~/MyAI_Lab/edge-frontier` (README + cases.md 事例台帳 + reading-list.md、desire-frontier と同型の資料中心・DOI 未登録)。context_files はその 3 ファイル。
2. **rotation-pick の非 daily 行数は 6 のまま** — daily line の追加は輪番位相を変えない (ADR-0012 で確定した akc/contemplative/aap/authorship/ans/desire の 6 日周期は不変)。毎朝 2 本 (輪番 1 + edge)。
3. **目的関数は既存 line と同一** (ADR-0009): 事例の網羅収集ではなく「エッジから何が学べるか」の抽出。有名事例の再確認 (裏付け) は成果ではない。エッジが見つからない日も baseline として正の出力 (発見ノルマなし)。
4. 部分失敗セマンティクス・metrics 合算は ADR-0011 決定 2〜4 をそのまま適用する (新機構なし、config 追加のみ)。

## Alternatives Considered

- **edge を輪番に入れる (7 日周期)**: 実装変更ゼロだが、エッジ事例は日単位で流れて埋もれるのが速く、運用者の指示 (毎日) とも異なる。棄却。
- **既存 desire-frontier repo に相乗り**: repo 新設不要だが、desire (需要が尽きた後の欲望側) と edge (活用強度の極端点) は問いが異なり、同一 repo の運用文脈を 2 line が読むと焦点が濁る。境界は edge-frontier README に明文化 (枯渇型証言は desire へ回す)。棄却。
- **daily-research 自身を接地にする**: repo 新設なしだが、daily-research の運用文脈はオーケストレーションの話で、研究上の前提・問いを持たない — ADR-0008 の設計意図 (repo の前提を動かす外部の動き) と噛み合わない。棄却。
- **汎用トレンドリサーチ line の再来ではないかの検討**: ADR-0007 で全廃した自由探索 line は「固定 domains の構造的飽和」と「関心乖離」が死因で、テーマ無限定の探索だった。edge は 3 本柱に限定された仮説 (エッジに学びが先に現れる) を持ち、接地 repo の台帳 (cases.md baseline) が前提を蓄積する — ADR-0008 の per-repo 型に適合しており別物と判断。ただし失効条件 (下記) で同じ死因を監視する。

## Consequences

- 良: エッジ事例の捕捉遅延が最大 1 日になる。既存 6 line の輪番位相は不変。
- 良: daily 機構の 2 例目の使用で、ADR-0011 の「速い line / 遅い line の cadence 分離」設計が検証される。
- 悪: 日次コスト・wall-clock が約 2 倍に戻る (ADR-0011 実測 baseline: 1 line ≒ $4.5 → 約 $9/日。ADR-0010 の `total_cost_mean <= 13` の内側)。最悪 2×(25+15) = 80 分。
- 悪: `fallback_used` / `pass2` が再び 2 line 合算の意味になる — 稼働中 DR-Expect (`fallback_rate` / `pass2_turns_*`) は次回 `/dr-review` で期間を分けて読む (ADR-0011 決定 4 / ADR-0012 Consequences と同じ扱い)。
- **失効条件 1 (ADR-0012 の教訓)**: レポートの収率の源が「外部の日次の動き」でなく在庫消化・既知事例の再確認に転じたら、edge を輪番へ戻して本 ADR の daily 判断を supersede する。判定は 4 週後 (2026-09-17 目安) の `/dr-review` で theme_rank 分布・cases.md への還元件数・鮮度自己申告を見る。
- **失効条件 2 (ADR-0007 の死因監視)**: 3 本柱の外のテーマが常態化する (関心乖離) か、同種事例の再確認が続く (構造的飽和) なら、line の停止または focus 再定義を検討する。
