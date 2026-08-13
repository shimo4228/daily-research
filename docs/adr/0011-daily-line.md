# ADR-0011: daily line (毎日実行 line) の導入と部分失敗セマンティクス

## Status

Accepted (ADR-0010 の決定 1 を一部 supersede)

## Date

2026-08-14

## Context

2026-08-14、需要側フロンティア（AI に頼みたいことが尽きた地点での価値）を探索する新研究ライン `desire`（repo: `~/MyAI_Lab/desire-frontier`）が発足した。この line の中心タスクは「一人称の枯渇証言が現れ始める瞬間の捕捉」で、2026-08-14 時点の baseline は英語圏 2 件・日本語圏 0 件 — 出現率の変化そのものが仮説検証のデータになる。

証言の出現は日単位のイベントであり、5〜6 日周期の輪番では捕捉が遅れる。一方、既存 5 line（akc / contemplative / aap / authorship / ans）は ADR-0010 の飽和診断（対象の変化速度 < 日次 cadence）が確定しており、輪番のままが正しい。運用者は「desire は毎日、既存 line は輪番で、毎朝 2 本」を指示した（2026-08-14）。

ADR-0010 の決定 1 は「当日担当 **1 line** を実行する」「ctl-015 は当日担当 line の 1 本存在判定」と定めており、本変更はこれを部分的に覆す。また 1 日複数 line の実行は、`metrics.jsonl` の `final_class` / `fallback_used` / `pass2` の意味と、git history 上の稼働中 `DR-Expect:` trailer（`no_report_count == 0` 等）に影響する。

## Decision

1. **config スキーマに `daily = true` を追加する**。daily line は輪番の周期から外れ、毎朝必ず実行される。`rotation-pick` は「非 daily 行の輪番 1 行（epoch 日 % 非 daily 行数）+ daily 全行（config 記述順）」を複数行出力する。daily の無い config では従来と同一出力（後方互換）。`daily` は bool 限定で、他の型は schema check（`_load_tracks`）が fail-fast に落とす（`daily = "false"` が true 扱いになる事故の防止）。
2. **orchestrator は per-line ループで全担当 line を実行する**。呼1（Opus 研究）+ ctl-015 ゲート + 呼2（Sonnet clarity）を line ごとに回す。401 (E_AUTH) は残 line を中断するが即 exit しない — 完走済み line の metrics / lint / wiki ingest / 通知を捨てないため（ADR-0006 の「計測の失敗で生成ジョブの成否を変えない」の複数 line 版）。
3. **部分失敗セマンティクス**: 日次 `final_class` は 全 line 成功 = `OK` / 一部失敗 = `E_PARTIAL`（新設）/ 全滅 = `E_NO_REPORT` とする。`E_NO_REPORT` の「その日レポート 0 本」という従来の意味を保ち、稼働中の `DR-Expect: no_report_count == 0` を部分成功の日が汚染しないようにする。部分失敗の通知は成功 line も併記する（alarm fatigue 回避）。exit は E_PARTIAL / E_NO_REPORT とも非ゼロ。
4. **metrics は 1 日 1 レコードを維持する**。複数 RUN は既存の `pass2` 合算、複数 CLARITY は新設の合算（`ok` は全 line 成功時のみ true）で旧レコード形に写像する。意味の変化として、`fallback_used` は「いずれかの line がリトライした」、`pass2` は「全 line の合算」になる — 稼働中の `DR-Expect: fallback_rate <= 0.05` / `pass2_turns_*` 系 expectation は次回 `/dr-review` で失効扱いとし、必要なら line 数で正規化した新 expectation を立て直す。
5. **初期構成**: `desire` のみ daily。毎朝 2 line（輪番 1 + desire）、日次コスト見込みは従来の約 2 倍（2026-08-14 実測 baseline: 1 line で total_cost=4.56 → 約 $9/日。ADR-0010 の `total_cost_mean <= 13` の内側）。wall-clock 最悪 2×(25+15) = 80 分。

## Alternatives Considered

- **desire も輪番に入れる（6 日周期）**: 実装変更ゼロで済むが、証言出現の捕捉が最大 6 日遅れ、line の中心タスク（出現瞬間の定点観測）と矛盾する。棄却。
- **desire 専用の第 2 launchd job**: orchestrator 無改修で毎日実行できるが、lock / metrics / lint / ingest が二重化し、1 日 2 レコードで `/dr-review` の集計も壊れる。棄却。
- **`final_class` を OK / E_NO_REPORT の 2 値のまま維持**: 実装は最小だが、部分成功の日が `no_report_count` に計上され、稼働中 DR-Expect が「レポートはあるのに NO_REPORT」という自己矛盾を報告する。棄却（E_PARTIAL 新設を採用）。
- **desire を Sonnet + 低 max-turns で軽量化**: 「見つからない」が既定の常時観測に Opus / max-turns 55 を毎日払う必要は薄い可能性がある。初期は挙動比較のため他 line と同一設定で開始し、4 週後の `/dr-review` でコスト実測とともに再検討する（保留 — 棄却ではない）。

## Consequences

- 良: 証言出現の捕捉遅延が最大 1 日になる。既存 5 line の輪番周期（5 日）と位相は不変。
- 良: daily フラグは汎用機構なので、将来「速い line / 遅い line」の cadence 分離に再利用できる。
- 悪: 日次コスト・実行時間が約 2 倍になる。`total_cost_mean` の余白が減る（13 に対し約 9）。
- 悪: `fallback_used` / `pass2` の意味が変わり、旧 DR-Expect の一部が失効する（決定 4 で対処）。
- 注意: レポート lint (ctl-016) と wiki ingest は日次一括のまま — line 数が増えても走り方は変わらない。
- 未対処（既知の残債）: orchestrator の per-line ループ本体は関数化されておらず変数スコープが目視レビュー依存（`run_line()` 化は次回リファクタ候補）。per-line ゲートの glob `{date}_{track}_*.md` は track 名の前方一致衝突に弱い（`desire` と `desire_jp` を並べない運用で回避）。README.ja.md は ADR-0010 以前から未同期（本 ADR とは別の負債）。
