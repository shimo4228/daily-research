# Plan: 夜間ヒルクライム（overnight-hillclimb）

- 起点: 運用者のチャット指示（2026-11-08 14:24 JST）。「品質改善の仮説を立てながらヒルクライムを登らせ、並列で、
  翌 08:00 の週次リセットまで自動で進める。週次使用量 95% まで使ってよい。Claude を呼ぶときは `claude -p` で
  サブスクを使う（API は枯渇するので使わない）。必要なツールは繋いでよい」
- 実行者: 本セッション（Opus 5.5）が主ループ。トラックごとに subagent を並列に走らせる
- 状態: 承認済み（運用者の上記指示を承認とする）
- 期限: 2026-11-09 08:00 JST（週次リセット）。使用量の上限: 週次 all models 95%

## 境界（このセッション全体）

| 項目 | 決め |
|---|---|
| 課金経路 | 改善のための `claude -p` は全部サブスク（OAuth）。本番の `config.toml`（api mode）は触らない。試験 run は worktree に subscription mode の config の写しを置いた隔離環境だけで回し、ログの `Billing: subscription` を確かめてから結果を使う |
| 本番への影響 | launchd の 05:00 run は main の作業ツリーを読む。main への取り込みは 04:40 までと 05:40 以後だけ。取り込む条件は `.claude/verify.sh` 緑 + 別 agent の review |
| 隔離環境 | vault・state・past_topics・metrics・logs は隔離環境の写し。本物の vault へは書かない。macOS 通知は shim で止める |
| 触らないもの | `.claude/verify.sh`（承認 hash）、`.claude/skills/`、permissions・hooks、本番の `config.toml`・`state/`・`past_topics.json` |
| 公開 | push しない（公開 repo）。費用の実数は `.notes/hillclimb/`（私的）にだけ書く |
| 評価の規律 | 文章の好み・読みやすさを LLM judge の点数で登らない（rule `evals.md`）。登る対象は、決定論の指標と、正解を持つ検査（埋め込んだ誤りの検出・出典との照合）と費用。読みやすさは非回帰の確認だけに使う |
| 少数標本 | 呼1 の A/B は 1 回数本で誤差と区別できない（rule `evals.md`: holdout 4〜8 件は noise）。呼1 の変更は機構が説明でき、指標が退行しないものだけを採り、効果の主張は `DR-Expect:` trailer で後日の live run に預ける |

## トラック

| # | 対象 | 登る指標 | 非回帰の確認 |
|---|---|---|---|
| T0 | 隔離 run の道具（`scripts/dev/`）: worktree + subscription config の写しで `DR_FORCE_TRACK` を回し、成果物と指標を集める | — | 本番の `scripts/daily-research.sh` を変えない |
| T1 | 呼2（`prompts/verification-protocol.md`）| 誤りを埋め込んだ原稿の検出・訂正率（私的な fixture、`.notes/hillclimb/`） | 正しい箇所の誤訂正、verify.json の妥当性、改稿量 |
| T2 | 呼1（両プロトコル・テンプレート）| ターン数・token・費用相当、lint、出典の新しさ、as-of の付与、問いの重複 | 呼2 の supported 率、line 状態、gate |
| T3 | コード | shell の無人 run の頑健さ（再現テスト付きの bug 修正）、`dr_pipeline.py` の境界の型（ruff ANN の ratchet）、テストの強さ（mutation score） | `.claude/verify.sh` 全体 |
| T4 | 文書 | 実物との食い違い 0（context-sync） | `tests/test-docs.bats` |

仮説の一覧と根拠は `.notes/hillclimb/hypotheses.md`（私的、数字を含むため）。結果の台帳は
`.notes/hillclimb/LOG.md`。

## 取り込みと戻し方

- 各トラックは自分の branch に commit する（1 仮説 1 commit、単独で revert できる形）。
- 主ループが verify と review を通して main へ取り込む。プロンプトを変える commit には `DR-Expect:` trailer。
- 05:00 の live run の後、その run のログ・metrics・lint を見て、取り込んだ変更が run を壊していないかを確かめる。
  壊していたら該当 commit を revert する。

## 終わり方

08:00 か、週次使用量 95% か、仮説が尽きたときに止める。最終報告に、取り込んだ変更・棄却した仮説と理由・
運用者の判断が要る点（承認、config の値、読みやすさの判定）を並べる。
