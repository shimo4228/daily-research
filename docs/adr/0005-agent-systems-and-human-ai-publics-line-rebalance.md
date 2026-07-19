# ADR-0005: 4ラインを Agent Systems + AI協働型公共圏 + Tech + Human Adaptation に再編する

## Status

Accepted

## Date

2026-07-19

## Context

ADR-0004 の再編後、daily-research は `attribution`（authorship-strategy + AAP）、`agent_cognition`（AKC + Contemplative Agent）、`tech`、`human_adaptation` の4ラインで稼働していた。ライン数は人間が毎日消化できる注意予算であり、探索対象を増やす場合も4本を超えないことが運用上の制約になった。

新しい探索対象は、AI agent自身の公共圏ではなく、**人間が主体・著者・判断者としてAIを使い、成果や方法を公開・評価・remix・継承する公共圏**である。この対象は、個人の学習・認知・スキル変化を扱う `human_adaptation`、model・tool・infrastructureを扱う `tech`、agent architectureと行為責任を扱うrepo-backed lineのいずれとも異なる。

AAPは語としてattributionを共有するauthorship-strategyよりも、agentの行為と責任配置を扱うAKC・Contemplative Agent側に運用上近い。一方、Authorship Strategyへの接続を新しい公共圏探索の必須条件にすると、候補生成が既存doctrineの周辺へ早期に狭まる。

## Decision

1. 日次ライン数は4本に固定する。
2. repo-backed lineは `agent_systems` 1本とし、Agent Knowledge Cycle（`akc`）、Contemplative Agent（`contemplative`）、Agent Attribution Practice（`aap`）の3 repoをマッピングする。
3. 自由探索 lineは次の3本とする。
   - `human_ai_publics`: 人間主体のAI協働型公共圏
   - `tech`: AI・developer technology
   - `human_adaptation`: 人間側の学習・認知・スキル形成
4. `human_ai_publics` は `report_variant = "public_sphere_radar"` を使う。レポートは公共圏の構造と実活動を検証し、末尾で `PILOT | WATCH | DROP`、最小pilot、人間の判断gate、撤退条件を示す。
5. `human_ai_publics` は独立した探索ラインとし、Authorship Strategyまたは他の研究repoへの接続を選定条件にしない。
6. Authorship Strategyをactive repo mappingから外す。repo、DOI、過去レポート、既存のgraph relationは削除・移行しない。
7. `agent_systems` は `agent_cognition` / `akc` / `contemplative` / `aap` を履歴aliasとして継承する。旧 `attribution` はauthorship-strategy由来の履歴を混入させるためaliasにしない。

## Alternatives Considered

### 5本目としてAI協働型公共圏を追加する

探索対象は保存できるが、日次の人間注意予算を増やし、全レポートを読んで判断する運用が崩れるため棄却した。

### `human_adaptation`を公共圏探索へ置き換える

個人の学習・認知・技能形成と、公共的な参加・評価・remixの制度層は異なる。前者の探索経路を失うため棄却した。

### 公共圏探索を`tech`へ含める

platform infrastructureと、人間の著者性・参加・評価の構造が同じスコアリングで競合し、どちらのsignalも弱くなるため棄却した。

### Authorship Strategyを公共圏ラインへマッピングする

既存conceptへの寄与を必須にすると、Einstein Arena型のvenue、AI-built artifact gallery、workflow remix commons、AI-assisted deliberationなどの候補を広く生成する前に探索範囲が狭まるため棄却した。

## Consequences

- 日次出力は4本のまま維持される。
- agentに関する外部研究は、knowledge cycle、contemplative design、accountability distributionを横断して選べる。
- `human_ai_publics` はagent-only network、private productivity tool、通常SNSのAI機能、generic model leaderboard、投機中心marketplace、休眠venueを候補から除外し、現在参加可能な人間主体の場を独立に探索する。
- Authorship Strategy固有のcoverage/frontierレポートは新規生成されなくなるが、過去の`attribution` Articleと既存graphは履歴として残る。
- 旧`attribution`配下のAAPレポートもtrack aliasでは自動継承しない。これはauthorship履歴の混入を避けるためのclean breakであり、既存Article自体は保持される。
