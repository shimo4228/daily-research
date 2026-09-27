# daily-research: rotation + 二層 eval (テーマ選別 / clarity 改稿) 再設計

## Context

/dr-review (2026-08-13) の診断: 生産は健全 (lint 全通過・fallback 0) だが、再設計後 10 日で
50 本生成に対し repo 還元はほぼゼロ。playbook は「8 日連続変化なし」「適正 cadence 2-3ヶ月」
と自己申告しており、5 本/日は読了可能量と変化速度の両方を超過。ユーザーの不満は
(1) テーマが響かない (飽和)、(2) 記事の可読性。

対策: 本数を 1 本/日に絞り (rotation)、浮いた予算で 1 本の品質を徹底的に上げる。
品質機構は zenn-content ADR-0008 (二本立て評価 + 改稿ループ) を無人実行向けに移植する。

ADR-0006 との関係: 同 ADR の死因診断は「verdict を消費する下流の不在」であり恒久禁止ではない
(ユーザー確認済み)。本設計は consumer を run 自身に固定した in-loop 型のため条件を満たす。
新 ADR には「衝突」ではなく「ADR-0006 の条件を満たす条件付き復活」と記す。

## 確定した決定 (grill-me 面談 2026-08-13)

1. **eval は in-loop 型に固定** — verdict は同じ朝の run 内で消費。スコア保存・蓄積なし
   (metrics.jsonl には発動記録のみ、theme_rank はノート frontmatter に残る)
2. **テーマ層主軸 + execution 層は clarity 特化** — テーマ候補複数生成 → 二値チェックリスト
   選別 → 最強 1 つを執筆。execution 側はフル craft judge でなく可読性レビューのみ
3. **弱テーマ日も見込みランク付きで通常執筆** (zenn 方式)。短縮・スキップしない
4. **2 呼び出し構成**: 呼1 = リサーチ + テーマ選別 + 執筆 (Opus)、
   呼2 = fresh-context clarity レビュー + 直接改稿 (Sonnet)。呼2 失敗は fail-open
   (改稿なし版が残る。ctl-015 に影響させない)
5. **毎日 1 line 均等輪番** (config 順、5 日周期、土日も実行)。重み付けは 4 週後に再検討
6. **成功基準**: 4 週後の /dr-review で判定 — (1) repo 還元件数の増加 (2) テーマランク分布
   (A 見込みが週 1 本以上) (3) 主観「読むのが楽しみになったか」。数値ノルマなし
7. **新規分野枠は見送り** — 必要なら別 ADR で「種の外部供給型」を設計 (変数を 1 つずつ動かす)

## 実装

### 1. rotation (orchestrator)

- `scripts/lib/dr_pipeline.py` に `rotation-pick` subcommand 追加:
  config.toml の line リストと日付から当日 line を決定論選択 (epoch_day % N。
  state ファイル不要・再実行冪等)
- `scripts/daily-research.sh`: per-line 全ループ → `rotation-pick` の 1 line のみ実行。
  `--model opus` に変更 (呼1)。既存の transient リトライ / 401 中断 / timeout は流用
- ctl-015 (レポート存在ゲート) を「当日担当 line の 1 本存在」判定に変更
  (`dr_pipeline.py` 側)。report_count の期待値 5 → 1

### 2. テーマ層 (呼1 プロンプト)

- `prompts/repo-research-protocol.md` に価値選定 step を置換する形でテーマ選別を追加:
  diff パス後にテーマ候補 2-3 件を根拠付きで生成 → 二値チェックリストで選別 →
  最強 1 件を執筆。全候補弱なら self-deepen 1 回 → それでも弱ければ見込みランクのまま執筆
- チェックリスト軸は `zenn-content/.claude/skills/theme-eval/SKILL.md` から移植
  (実装時に読んで無人実行向けに削る。二値分解・named verdict は global `llm-as-judge`
  skill 準拠、集計スコア禁止)
- `templates/report-template.md`: frontmatter に `theme_rank: A見込み|B見込み|Deepen後`
  を追加。固定 2 節 (機会メモ / ソース) は不変 — ARTICLE_SECTIONS の変更なし

### 3. clarity 層 (呼2、新規)

- 新規 `prompts/clarity-review-protocol.md`: 当日レポート 1 本だけを読み
  (研究文脈なし = 本物の初見読者)、前提知識ゼロ読者としてつまずき箇所を列挙 →
  span 単位で直接改稿。欠陥検出限定 — 内容追加・追加リサーチ・ソース節/機会メモ/
  as-of 日付/theme_rank の改変は禁止。改稿は 1 周のみ (zenn の「反復は 2-3 回で
  voice 劣化」知見の無人版として最小回数)
- `daily-research.sh` に呼2 を追加: model sonnet、`--allowedTools` は
  Read + 当日ノート絶対パスのみの Write/Edit。失敗時は log に記録して正常終了 (fail-open)
- metrics.jsonl に `clarity_pass: {ran, ok, cost, turns}` を追加
  (`dr_pipeline.py` metrics-append / backfill 対応)

### 4. ドキュメント / ADR

- `docs/adr/0010-rotation-and-two-tier-eval.md` を /adr-writer で起案。
  ADR-0006 (条件付き復活)・ADR-0008/0009 (エンジン維持) との関係を明記
- CLAUDE.md / RUNBOOK / config.example.toml 同期
- commit に DR-Expect trailer: `report_count_min >= 1` / `total_cost_mean <= 13` /
  `lint_hard_count == 0`

### 5. テスト

- bats: rotation-pick の決定論選択・呼2 fail-open・ctl-015 単一 line 判定
- pytest: `dr_pipeline.py` の rotation-pick / metrics スキーマ拡張 / lint 変更
- `.claude/verify.sh` を通す

## 触らないもの (non-goals)

- エンジン: diff-first state 層・citation ゲート・前提挑戦パス・past_topics dedup・
  repo read-only 三層 (ADR-0008)
- 事後採点 job・Slack 通知の復活・graph.jsonld・wiki ingest 経路
- 新規分野枠 (別 ADR へ deferred)
- zenn の mechanical_checks.py 移植 (今回は LLM clarity のみ。決定論 slop 検査は将来)

## コスト見込み

呼1 Opus ~$8-11 + 呼2 Sonnet ~$1-2 ≒ $10-13/日 (現状 5 line Sonnet の $11-12 と同等)。

## 検証

1. `bats tests/` + `.venv/bin/python -m pytest` 全通過
2. 手動 1 run (別ターミナルで `./scripts/daily-research.sh`) — rotation 選択・
   theme_rank frontmatter・呼2 改稿・metrics 記録を確認
3. 呼2 を意図的に失敗させ fail-open を確認 (改稿なし版が vault に残り exit 0)
4. 翌朝 launchd 実測を metrics.jsonl で確認
5. 4 週後 /dr-review で成功基準判定 (還元件数・ランク分布・主観)
