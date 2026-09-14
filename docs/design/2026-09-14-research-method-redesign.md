# リサーチ方法の再設計 — 根拠の要約（2026-09-14）

ADR-0017 の判断材料。原本は運用者の harness 側 plan ファイル（`~/.claude/plans/` の
`deep-research-result-claude-2026-09-14.md` / `deep-research-result-codex-2026-09-14.md` /
`optimized-gathering-mitten.md`、repo 外・可変）にあり、ここは repo から検証できる範囲の要約。

## 手順

1. 同じ依頼 prompt（対象システムの固定条件 / 変えてよい条件 / 運用履歴 / 既読の一次資料 / 6 領域の
   問い）を Claude と Codex のディープリサーチに渡し、2 本の報告を得た。
2. 両報告が引用した arXiv 24 本（Claude 11 + Codex 15、重複除去後 24）の実在と題名を arXiv の abs ページで
   照合した。**照合したのは実在であって、各報告が要約した主張の正確さではない**。
3. 両報告の交点を設計に採り、設計 plan を Codex（gpt-6-astra、reasoning high、read-only sandbox）に
   premise challenge させた（REFUTE / MISSING / ALTERNATIVE、VERDICT: premise-hole）。

## 2 報告の交点（設計に採ったもの）

- 単一 agent を軸にする。orchestrator–worker は並列分解できる breadth-heavy な課題向け（Codex 報告が
  Kim et al., arXiv 2512.08296 の 180 構成比較を引き、逐次課題で multi-agent が 39〜70% 悪化と要約。
  **二次情報、原典未照合**）。
- repo 文脈は渡す。第 8 の自由ラインは作らない。7 line 輪番は残す（読者反応の記録が無く bandit の報酬が無い）。
- 内容状態（通常記事 / 短報 / 更新なし / 保留）を正常な結果にし、毎回新テーマを完結させる義務を捨てる。
- 短い line brief を最初に渡し、選定後に repo 詳細を読む。台帳の open task を選択条件にしない。
- 過去テーマ履歴を問い粒度にする（同じ問い + 同じ答え = 禁止 / 同じ問い + 新証拠 = 更新可 / 同じ topic +
  別の問い = 可）。
- 根拠ファイル（主張・原典・locator・時点・条件・出所系譜・取得状態）と、原典を再取得して照合する
  fresh-context の別 pass。検証結果を metrics へ。
- 機会メモの正本を state に置き、pending / resolved / contradicted / expired / unverifiable の状態を持つ。
- 停止規則は「次の検索が何を解決するかを言えなくなったら止める」。

## 2 報告で分かれ、判断で決めたもの

- 工程分割: Codex は探索 Opus → 執筆 Sonnet → 検証 Opus の 3 プロセス、Claude は 1 プロセス多パス。
  執筆を別モデルへ渡すと素材圧縮で条件が落ちる（Codex 自身の弱点記述）ため、探索 + 執筆 / 検証 + clarity の
  2 プロセスにした。
- 導入順: Claude は段階導入（週 1 は問い生成だけ）を推奨。運用者は一括導入を選んだ。
- 本文の固定見出し撤去: Claude は「執筆パスは定型を保つ」、Codex は「見出し名を強制しない」。撤去は
  運用者の編集判断（旧構造が冗長）で、論文の実証ではない。

## Astra（Codex）の plan 反証 8 件と採否

1. REFUTE 採用: 復元する `line-brief` が context_files を「Step 1 で必ず Read」と注入し、config の focus に
   「使い道優先」の文言が残るため、「短い文脈から始める」が打ち消される → line-brief の出力を変え、focus の
   選択条件文言を削った。
2. REFUTE 採用（言い換え）: Price of Format（arXiv 2505.18949）は instruction tuning の構造化テンプレートの
   実証で、見出し撤去の根拠にならない → 編集判断として記述。
3. REFUTE 採用: 不一致を「〜と報じられている」へ弱めても裏付けは生まれない → 原典に合わせて訂正、
   合わせられなければ文を削る、帰属表現は二次報道であることを原典で確認できる場合だけ。
4. MISSING 一部採用: 呼2 の訂正が state に反映されない、呼2 失敗で未検証版が公開される → 呼2 失敗を
   `unverified` として通知・metrics に出す。state は検証前の版であることを ADR の限界に明記。
5. MISSING 採用: 取得失敗と quiet を区別できない → receipt に `reason_code`、検索 0 回や fetch_failed の
   quiet を `suspect` として別計上。
6. MISSING 採用: verifier の見逃しを自己申告では測れない、`unsupported_rate` の分母、verify.json の鮮度 →
   分母から unverifiable を外し、`unverifiable_rate` を追加、呼2 前に verify.json を削除、既知誤りを植えた
   fixture で手動確認。
7. MISSING 採用: 資料を読んで問いを更新する往復が無い → 問いの改訂を 1 回まで許可、根拠ファイルに元の問いを残す。
8. ALTERNATIVE 一部採用: 主要主張 3〜5 件に絞り全件照合 → claim 3〜6 件に上限、呼2 は全件照合。長さの
   上限は 3,000 字のまま。

## 費用・時間の導出

- 実測（`metrics.jsonl`、2026-08-13〜09-05、輪番 1 line + edge daily）: 2 line の日の pass2 費用平均 $8.17
  → 呼1 ≈ $4.1/line、呼2（旧 clarity）≈ $0.47/line。turns/line p50 42、p90 48。所要は 呼1 5〜8 分、
  呼2 1.5〜3 分。
- 3 line の見込み: 呼1 $4.1〜4.7 × 3 = $12.3〜14.1、呼2（WebFetch + 30 turn）$0.7〜1.0 × 3 = $2.1〜3.0 →
  $14.4〜17.1。Review-when の上限 18 はその天井。
- 最悪所要: 呼1 1500 s × 2 attempt + 呼2 1200 s = 70 分/line × 3 = 210 分（05:00 起動で 08:30）。典型は
  25〜35 分。
