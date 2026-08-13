# ADR-0010: rotation 単一 line 実行と in-loop 二層 eval (テーマ選別 / clarity 改稿) の導入

## Status

Accepted — 決定 1（当日 1 line / ctl-015 の 1 本判定）は [ADR-0011](0011-daily-line.md) により一部修正（daily line の追加実行と部分失敗セマンティクス）

## Date

2026-08-13

## Context

2026-08-13 の `/dr-review`（前回 2026-07-29 以来、ADR-0008/0009 の再設計を跨ぐ初レビュー）が次を示した。

生産側は健全である。直近 10 日（ADR-0008 以後、2026-08-04 以降）で lint hard 違反 0、fallback 0/10、コスト水準も安定（実数は `metrics.jsonl`）。

しかし消費・還元ループがほぼ停止している。再設計後 10 日で 50 本のレポートを生成したのに対し、研究 repo 側の wiki-harvest / daily-research ledger への還元記録は `ans` の数件のみだった。`akc` は daily-research 由来の還元が 0 件で、ledger の最終更新は 07-08 のまま止まっている。

line の playbook 自身が飽和を自己申告している。`akc` は「COLM 2026 通知 8 日連続で変化なし」「観測のみ」、`authorship` は「この論点の cadence は 2〜3 ヶ月」と記録しており、日次 cadence が対象の変化速度を上回っている状態が構造化していた。per-line turns の実測は p50≈35 / max 51 で、`--max-turns 55` の上限に対し余白 4 turns の日が 1 回あった。

運用者の不満は 2 点に整理できる。(1) テーマが響かない（飽和）。(2) 記事の可読性 — ADR-0009 が記述規律 (b) 背景解説で対処したはずの問題が残存している。

参考にした外部設計は zenn-content の ADR-0008 `two-tier-eval-and-revision-loop`（2026-08-12、別 repo）の二本立て評価（テーマ層 = 記事の上限 ceiling / execution 層）である。その外部実証（as-of 2026-08-12、モデル世代依存）は次を示している。

- 二値チェックリスト分解は Likert 採点を評価者間一致で上回る（CheckEval / TICK / BinEval）。
- 自己批評は self-preference と blind spot（64.5%）で構造的に破綻し、fresh-context の別プロセス判定が優る（CCR、2026-03）。
- 反復改稿は 2〜3 回で頭打ちし voice ドリフトが進行する（Voice Under Revision、2026-04）。

ADR-0006 との関係も本レビューで明確化した（運用者確認、2026-08-13）。ADR-0006 の「LLM judge を復活させない」は恒久禁止ではなく、「verdict を消費して行動を変える下流の不在」という死因診断に基づく条件付き判断だった。consumer を先に確定すれば同じ死に方をしない、という条件文として読む。

決定は 2026-08-13 の grill-me 面談（対話セッション内。一次記録は本 ADR）で確定した。

## Decision

1. **rotation 単一 line 実行**: 毎朝、config.toml の line 群から当日担当 1 line を `dr_pipeline.py rotation-pick`（epoch 日 % line 数。state ファイル不要、同日再実行は冪等、周期は config 記述順）で決定論選択して実行する。土日も実行する。各 line の再訪間隔は 5 line 構成で 5 日。均等輪番で開始し、重み付けは 4 週後の `/dr-review` で再検討する。ctl-015 レポート存在ゲートは「当日担当 line の 1 本存在」判定に変更する。
2. **eval は in-loop 型に固定する**: verdict の消費者は同じ朝の run 自身（テーマ再選定・改稿）とする。スコアの保存・蓄積はしない — `metrics.jsonl` には呼2 の発動記録（`clarity_pass` = ran/ok + 実測）のみを記録し、`theme_rank` はノート frontmatter に残す。これは ADR-0006 の条件（consumer 先行確定）を満たす条件付き復活であり、ADR-0006 の否定ではない。
3. **テーマ層（呼1 内、プロトコル Step 3 を置換）**: diff パス後にテーマ候補 2〜3 件を生成し、二値チェックリスト（T1 圧縮 / T2 非自明性 / T3 新規性 / T4 一次到達性 / T5 接続 / T6 非寄生）+ 反証プレッシャー 2 問で選別し、named verdict（A見込み / B見込み / Deepen）を出す。全候補 Deepen なら self-deepen 1 回のみ。弱テーマ日も見込みランク付きで通常執筆する — 却下ゲートにはしない（発見ノルマなし原則の維持）。チェックリストは zenn-content `theme-eval` skill から無人実行向けに縮約移植する。
4. **execution 層は clarity 特化の呼2**: 執筆後、fresh-context の別プロセス（`claude -p` 2 回目、model sonnet、15 分 timeout、リサーチ過程の文脈なし、`--allowedTools` は Read + 当日ノートのみの Edit）が初見読者としてつまずき箇所を span 単位で直接改稿する。cwd は daily-research のまま — repo-local settings のプラグイン無効化を効かせるための意図的トレードオフで、daily-research の CLAUDE.md（記述規律の知識）はロードされる。欠陥検出限定 — 新事実の追加・ソース節/機会メモ/frontmatter の変更は禁止、改稿は 1 周のみ。失敗は fail-open（未改稿 — timeout / max-turns 超過時は部分改稿 — の版が残り、ctl-015 / FINAL_EXIT に影響しない）。正本は `prompts/clarity-review-protocol.md`。
5. **モデル配分**: 呼1 = Opus（リサーチ + テーマ選別 + 執筆)、呼2 = Sonnet。rotation で浮いた予算を主執筆の格上げに充てる。日次コスト見込みは現行 5 line Sonnet 合算と同等（実数は `metrics.jsonl` で追跡）。
6. **成功基準**: 4 週後の `/dr-review` で判定する — (1) repo 還元件数の増加、(2) `theme_rank` 分布（A 見込みが週 1 本以上）、(3) 主観「読むのが楽しみになったか」。数値ノルマは課さない。導入 commit に `DR-Expect:` trailer（`report_count_min >= 1` / `total_cost_mean <= 13` / `lint_hard_count == 0`）を付け、次回 `/dr-review` で機械突合する。

## Alternatives Considered

### 事後採点の復活（別 job が毎朝レポートを採点して記録）

ADR-0006 の死因「消費者なき採点」の再現になるため棄却。

### 弱テーマ日の短縮ダイジェスト切替 / 次 line へのスロット委譲

面談で推奨案として提示されたが、運用者は zenn 方式（弱くても見込みランク付きで通常執筆）を選択し、毎日 1 本の一定した読み物を維持することにした。棄却。

### 3 呼び出し構成（テーマ judge も fresh-context 別プロセス）

zenn 完全形に忠実だが、無人実行の故障面とコストが最大になる。テーマ選別は二値チェックリスト形式なら run 内でも比較的健全（二値分解の評価者間一致の実証）と判断した。棄却。

### 1 呼び出し構成（run 内自己批評のみ）

自己批評の blind spot（64.5%）に加え、研究文脈を持つプロセスは「初見の読者」を演じられない。clarity レビューは文脈を持たない別プロセスであること自体が価値である。棄却。

### 両呼び出し Sonnet（コスト削減優先）/ 両呼び出し Opus

前者は品質向上を構造だけに依存させる。後者は clarity の欠陥検出に Opus は不要でコスト増（同等予算の約 1.5 倍）になる。棄却。

### 重み付き輪番（還元実績のある line を高頻度化）

還元データが 10 日分しかなく時期尚早。均等で開始し 4 週後に再検討する。棄却。

### 成功基準を還元件数のみの hard KPI にする / 主観のみにする

前者は「還元したくなるレポートを書かせる」Goodhart 圧を生む。後者は問題発見の遅れ（今回の「なんとなく響かない」の再現）を招く。棄却。

### 新規分野枠の同時導入

自由探索 line は過去 3 回廃止（2026-05-27 → ADR-0004 復活 → ADR-0007 全廃 → ADR-0008 削除）であり、「復活には別の実行形の設計が必要」（CLAUDE.md）。rotation + 二層 eval と同時に入れると効果の切り分けができない。見送り — 必要なら別 ADR で「種の外部供給型」を設計する。

## Consequences

### Positive

- 読む量が 5 本/日 → 1 本/日になり、還元ループが回る前提条件（読了可能性）が回復する。
- 各 line の再訪間隔 5 日は、playbook 実測の変化速度（7-8 日変化なし、cadence 自己申告 2〜3 ヶ月）と釣り合う。diff-first 設計は間隔が延びるほど差分が濃くなる方向に働く。
- 日次コスト同等のまま主執筆が Opus に格上げされる。
- 可読性は「本物の初見読者」（研究文脈を持たない別プロセス）が仕上げる。

### Negative

- 各 line の機会検出が最大 5 日遅れる — 期限付き機会の見逃しリスクが増える（機会メモの失効日規律と、機会があれば watched-sources の cadence 短縮で個別ヘッジする）。
- 呼2 が新たな故障面になる（fail-open で封じ込め、発動記録は metrics で監視する）。
- Opus 化で呼1 の turns / 25 分 timeout の余白が変わりうる（Sonnet 実測 max 51 vs 上限 55。超過が観測されたら `--max-turns` 引き上げを別途判断する）。
- `theme_rank` は self-assessment であり、甘さは構造的に残る（反証プレッシャー 2 問で緩和、分布のドリフトは `/dr-review` で監視する）。
- 呼1 が失敗した日はレポートが 0 本になる（部分成功が存在しない）。落ちた line の catch-up は行わず、翌日は輪番の次の line に進む。

### Neutral / Follow-ups

- [ADR-0006](./0006-self-improvement-loop-human-consumer.md) は維持する — 事後採点・無人週次ダイジェスト・プロンプト自動改変は引き続き作らない。本 ADR が許すのは verdict が run 内で消費される in-loop 型のみである。
- [ADR-0008](./0008-per-repo-in-context-research.md) のエンジン（per-repo cwd 実行・diff-first state・citation ゲート・前提挑戦パス・repo read-only 三層）と [ADR-0009](./0009-explanatory-report-and-brief-retirement.md) の出力形式（自由形式解説レポート + 固定 2 節）は無変更。
- ADR-0009 の「行動ループが閉じない」トレードオフは本 ADR でも維持する — 還元は運用者の読書経由のままである。
- 4 週後（2026-09 中旬）の `/dr-review` が本 ADR の効果判定を行う。

## References

- `prompts/repo-research-protocol.md` Step 3 — テーマ選別の正本
- `prompts/clarity-review-protocol.md` — 呼2 の正本
- `scripts/lib/dr_pipeline.py` `rotation-pick` / `clarity_pass` — 実装
- zenn-content `docs/adr/0008-two-tier-eval-and-revision-loop.md` — 参考設計と外部実証の出典
- `.notes/dr-review-state.json` / `metrics.jsonl` 2026-08-13 — レビュー実測
