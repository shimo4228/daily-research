# daily-research 自己改善機構（計測 → 評価 → 改善ループ）

## Context

毎朝 launchd で自律実行する daily-research には評価・改善の仕組みがなく、改善がユーザーの ad-hoc なアイデアに依存していた（実例: max-turns 15 に根拠の記録がなく 07-29 に turns 16 で死亡 / プロンプト変更の効果測定なし / 失敗検出が「人間がログを見て気づく」依存）。

/grill-me の結論として、**旧 LLM-as-Judge の死因は「コスト」ではなく「スコアを消費する下流の不在」**と再診断した。したがって judge の復活はせず、「判断は人間のまま、判断材料の供給と効果測定を機構化する」設計とする。

### grill で確定した決定事項

1. **Consumer = 人間**。機械は計測・異常検知・材料整形まで。改善判断の自動化はしない（human-gate / generator-verifier gap 整合）
2. **Signal = 4 種、すべて LLM 再採点なしの決定論収集**: ①決定論的レポート lint ②運用 telemetry 構造化 ③wiki 品質注記（FLAGGED / 一次未照合）の回収 ④repo 還元トレース。④のみ v1 では「既存 ledger から取れる範囲」に格下げ（wiki-harvest 側の規約変更は越境なので保留）
3. **消費形態 = 対話 skill `/dr-review`**。収集・蓄積は決定論 script が日次で行い、解釈・改善提案はユーザーが週 1 目安で対話セッションから呼んだときだけ行う。無人 LLM ジョブは増やさない
4. **効果測定 = `DR-Expect` commit trailer**。prompt / config 変更の commit に「動くはずの metric と方向」を機械可読 1 行で残し、次回 /dr-review が telemetry 実測と自動突合する
5. 事前調査で判明した事実: ingest 率は 518 本中 508 本 (98%) で判別力ゼロ → 品質信号は wiki 側の FLAGGED / 推定扱い注記を使う。logs/ は 30 日ローテーションで SUMMARY 履歴が消失中 → JSONL 永続化は急務

## 実装

### 1. telemetry 永続化（`metrics.jsonl`、gitignored）

- `scripts/lib/dr_pipeline.py` に `metrics-append` サブコマンド追加（stdlib のみ）: Pass1/Pass2 の cost / turns / duration / searches、fallback 使用有無、最終 class（OK / E_NO_REPORT 等）、当日レポート数を 1 行 JSON で `metrics.jsonl` に append
- `daily-research.sh` の Pass 3 の後（exit 直前）に non-fatal で呼ぶ。既存の `PASS1_JSON` / `PASS2_JSON` / `PASS2_CLASS` / `REPORT_COUNT` をそのまま渡す（daily-research.sh:270-342 の変数を再利用）
- **backfill**: 既存 `logs/*.log` の SUMMARY 行を parse して過去分を投入する `metrics-backfill` サブコマンド（ワンショット）
- `metrics.jsonl` と `metrics.example.jsonl` の扱いは `past_topics.json` の慣例に合わせる（.gitignore 追加。repo は public、コストは個人データ）

### 2. 決定論的レポート lint（ctl-016）

- `dr_pipeline.py report-lint` : 当日レポート各ファイルに対し、出典 URL 数 ≥5 / テンプレ必須節の存在 / 飽和 cluster 違反（cluster-report の禁止リストと突合）/ 本文長下限、をバイト列判定
- 結果は metrics.jsonl の当日行に格納。**hard fail（出典 0 件・必須節欠落）のみ** `log WARN` + `notify`（non-fatal、ctl-015 と同パターン）。soft は蓄積のみ

### 3. wiki 品質注記の回収 + repo 還元トレース（review 時に実行）

- `dr_pipeline.py wiki-quality-scan <vault_path>` : `wiki/concept/*.md` から `FLAGGED` / 「一次未照合」注記を grep し、`[[<report-filename>]]` リンクでレポート・line に逆引き集計
- repo 還元は各研究 repo の wiki-harvest ledger（`.notes/`）を best-effort grep。取れなければ「データなし」と正直に表示（silent cap 禁止）
- 日次実行には入れない（vault 注記は ingest 後に育つため、review 時点の再スキャンで十分）

### 4. `/dr-review` 対話 skill（project skill）

- `daily-research/.claude/skills/dr-review/SKILL.md`（単一 repo 固有 → project overlay。`user-invocable: true`）
- 手順: ①metrics.jsonl 集計（分布・トレンド・fallback 率）②report-lint / wiki-quality-scan 実行 ③前回 review 以降の `git log` から `DR-Expect:` trailer を拾い実測と突合（達成 / 未達 / 未判定）④異常・劣化トレンドから改善候補を提案 — **判断と着手はユーザー**
- 最終 review 日時は `.notes/dr-review-state.json` に記録
- skill 本文に DR-Expect trailer の書式規約を正本として記載し、CLAUDE.md からポインタ

### 5. review リマインダー

- daily-research.sh 末尾で「前回 /dr-review から N 日」をログに出し、N ≥ 10 なら notify 1 行（non-fatal）

### 6. テスト + ドキュメント

- pytest: metrics-append / metrics-backfill（SUMMARY 行 parse）/ report-lint / DR-Expect parse。fixtures に実ログ形式のサンプル
- bats: daily-research.sh の metrics 呼び出しが non-fatal であること（e2e-mock に追加）
- **ADR-0006** 起草: 「自己改善ループの設計 — LLM judge 復活ではなく決定論収集 + 人間 review」。ADR 3 条件（可逆でない設計方針 / 将来 "なぜ judge を復活させないのか" と問われる / 無人 weekly job・自動閉ループとの実トレードオフ）を満たす
- CLAUDE.md の設計方針節に 3 行程度で追記

## Scope 外（明示）

- LLM-as-Judge の復活・LLM による品質再採点
- プロンプトの自動改変・自動 A/B（human-gate と衝突）
- wiki-harvest / vault 側スクリプトへの規約追加（v1 保留。効果が見えたら別作業で）

## Verification

1. `metrics-backfill` を既存 logs/ に実行し、07-27〜29 の 3 日分が JSONL 化されること
2. `report-lint` を当日 4 レポートに実行し、全 PASS（または実在する違反の正検出）を確認
3. `wiki-quality-scan` が今日の agent_systems レポートの FLAGGED 注記を正しく逆引きすること（実データで検証済みの grep パターンを使用）
4. pytest + bats 全 PASS、カバレッジ ≥ 80%（新規 subcommand 分）
5. `/dr-review` を対話セッションでドライラン、digest 5 節（telemetry / lint / wiki 注記 / DR-Expect 突合 / 改善候補）が出ること
