# ADR-0006: 自己改善ループを「決定論収集 + 人間 consumer」で構成し、LLM judge を復活させない

## Status

Accepted

## Date

2026-07-29

## Context

daily-research は毎朝の自律実行に対して評価・改善の仕組みを持たず、改善はユーザーの ad-hoc なアイデアに依存していた。具体的な症状は 3 つ:

1. **失敗検出が人間のログ閲覧に依存** — 2026-07-29 朝、Pass 1 の max-turns 切れ → フォールバック Sonnet が質問だけして end_turn する silent fail が発生（同日 ctl-015 で fix）
2. **品質劣化の検出面が存在しない** — レポートは出るが質が落ちるケースは誰も観測していない
3. **改善変更の効果が測定されない** — max-turns 15 は根拠の記録がなく（前日 23 turns で通り当日 16 で死亡）、プロンプト刷新の効果測定も行われていない

過去に LLM-as-Judge 評価フレームワーク（6 次元ルーブリック × Opus judge）を運用したが 2026-02 に停止、2026-06-29 に完全削除した。当時の停止理由は「コスト対効果」とされたが、本 ADR の設計にあたり死因を再診断した: **judge のスコアを消費して行動を変える下流が存在しなかった**（スコアが高くても低くても翌日のパイプラインは変わらない）。コストは consumer 不在を顕在化させた引き金にすぎない。この再診断が本設計の出発点である — どんな評価機構も、出力の consumer を先に確定しなければ同じ死に方をする。

設計の事前調査で 2 つの事実が判明した:

- レポートの wiki ingest 率は 518 本中 508 本（98%）で、「ingest されたか」は品質の判別信号にならない。一方 wiki 側には ingest 時に「FLAGGED（source-fidelity 懸念）」「一次未照合のため推定として扱う」というレポート単位の品質注記が既に生成されており、決定論的に回収可能
- logs/ は 30 日ローテーションで SUMMARY 履歴（cost / turns / searches）が消失し続けており、分布に基づく閾値設定が構造的に不可能だった

## Decision

計測 → 評価 → 改善のループを次の役割分担で構成する:

1. **Consumer は人間** — 機械は計測・異常検知・材料整形まで。改善判断の自動化（プロンプト自動改変・自動 A/B）はしない。LLM 単独の承認経路を作らない
2. **Signal は 4 種、すべて LLM 再採点なしの決定論収集**:
   - 運用 telemetry: `metrics.jsonl`（gitignore）への run 記録永続化 + 既存ログからの backfill（`metrics-append` / `metrics-backfill`）
   - 決定論的レポート lint（ctl-016）: 出典 URL 数・必須節・本文長・飽和 cluster 違反。hard fail（ソース節不在・出典 0 件）のみ即日 notify、soft は蓄積（`report-lint`）
   - wiki 品質注記の回収: FLAGGED / 一次未照合注記を `[[レポート]]` リンクで line 別に逆引き（`wiki-quality-scan`）
   - repo 還元トレース: wiki-harvest ledger からの best-effort 集計（v1 は規約追加なし）
3. **消費形態は対話 skill `/dr-review`**（週 1 目安） — 集計・解釈・改善候補の提示を対話セッションで行い、採否はユーザー。無人 LLM ジョブは増やさない。daily run は「前回 review から N 日」を記録し、10 日超で notify
4. **効果測定は `DR-Expect` commit trailer** — 効果を意図した変更の commit に「動くはずの metric と方向」を機械可読 1 行で残し、次回 /dr-review が `expect-check` で実測と自動突合する（ACHIEVED / NOT_ACHIEVED / INSUFFICIENT_DATA）

## Alternatives Considered

### LLM-as-Judge の復活（コスト最適化版）

Haiku 等の安価モデルで再採点する案。consumer 不在という真因を解決しないため棄却。品質のうち機械判定可能な部分は決定論 lint が、意味的な部分は既存の人間 + LLM 協働（wiki ingest 時の source-fidelity 注記）の副産物回収が担う。

### 無人週次ダイジェスト job（launchd + claude -p）

週次でダイジェスト md を自動生成する案。「読まれない週次レポート」は「消費されないスコア」と同型の死に方をする。無人 job の故障面が 1 つ増え、LLM コストが恒常化するため棄却。対話 skill なら人間の同席が構造的に保証される。

### 評価結果によるプロンプト自動改変（完全閉ループ）

Anthropic のループエンジニアリングの完全形だが、generator-verifier gap（提案者と検査者が同一システム）と human-gate 原則（LLM 単独の承認経路を作らない）に衝突する。public repo で日次 $3.6〜9.7 の上にコストも乗る。棄却。

### 計測基盤のみ先行（consumer 未定のまま蓄積）

judge の二の舞リスク（consumer 不在の計測）があるため、consumer（人間 + /dr-review）の確定とセットでのみ導入。

## Consequences

- 改善アイデアの供給源が「ユーザーの思いつき」から「毎週の実測ダイジェスト」に変わる。判断自体は人間に残るため、MyAI_Lab の value-layer インサイト（アイデアは没頭の摩擦から湧く）と衝突しない — 機構が供給するのは摩擦の可視化であってアイデアの製造ではない
- max-turns 等の閾値は分布（p50 / p90 / max）を根拠に設定できるようになる。導入時の backfill で直近 31 日分 32 run を救済済み
- 変更の効果が DR-Expect で記録・検証されるため、「根拠の記録がない設定値」は原理的に再発しなくなる（trailer を付ける規律には依存する）
- LLM コストの増分はゼロ（全収集が bash + stdlib python3）。増えるのは /dr-review 対話セッションの人間時間のみ
- metrics.jsonl は個人データ（コスト実数値）のため gitignore。public repo にはスキーマ例（metrics.example.jsonl）のみ置く
- repo 還元トレースの本格化（wiki-harvest 側の記録規約）は保留 — v1 の運用で価値が見えたら別 ADR で扱う
