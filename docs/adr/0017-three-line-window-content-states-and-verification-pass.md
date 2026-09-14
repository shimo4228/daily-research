# ADR-0017: per-repo 輪番へ戻し、3 line/日の window・4 内容状態・原典照合 pass・問い粒度の履歴を導入する

## Status

Accepted。[ADR-0016](0016-discovery-first-edition.md) の Decision 5（旧設計の適用範囲の退役）を supersede する。
0016 が新経路に適用しないとした ADR のうち、[ADR-0008](0008-per-repo-in-context-research.md) /
[ADR-0009](0009-explanatory-report-and-brief-retirement.md) / [ADR-0010](0010-rotation-and-two-tier-eval.md) /
[ADR-0014](0014-trend-explanation-report.md) / [ADR-0015](0015-reader-contract-style-rules-and-edge-idea-harvest.md) /
[ADR-0006](0006-self-improvement-loop-human-consumer.md)（lint・レビュー機構）/ [ADR-0011](0011-daily-line.md)（daily 機構は
schema に残す）/ [ADR-0012](0012-desire-back-to-rotation.md)（daily → 輪番へ戻す先例、本 ADR の edge に再適用）は再び
有効。[ADR-0001](0001-research-repo-feedback-engine.md) / [ADR-0002](0002-reports-as-frontier-diff.md) /
[ADR-0003](0003-cross-line-knowledge-cycle.md) の repo 中心の目的は 0008 以降の系譜のとおり有効（実装基盤は 0008 で
付け替え済み）。ADR-0010 の決定 1（当日 1 line）と決定 4（呼2 = clarity のみ）、[ADR-0013](0013-edge-daily-line.md) の
edge daily はここで置き換える。ADR-0016 の Decision 1〜4（discovery 号の実行経路）は実装ごと退役した（記録は
7877a11、削除は 48c8908）。0016 が各 ADR に付けた「2026-09-06: ADR-0016 を参照」の注記は 48c8908 の復元で消えた
ため、本 ADR で日付つき注記を付け直した。

## Date

2026-09-14

## Context

ADR-0016（2026-09-06）は「蓄積した文脈が探索を収束させている」という運用者仮説に基づき、repo 文脈を渡さない
自由探索の日刊号へ再編した。8 日運用（2026-09-07〜14、8 号）した結果、運用者は通読の印象として「無関係な話題ばかり」と
評価し（2026-09-14 の会話。定量記録は無い）、8 月中旬までの per-repo リサーチライン方式へ戻すことを決めた。同時に、旧方式の不満（似た題材が続く、読む量が
多い、節構成が冗長）を構造で直すことにした。

戻し方の根拠として、リサーチ方法の設計を 2 系統のディープリサーチ（Claude、Codex）に同じ依頼 prompt で
問い、引用された arXiv 24 本の実在（主張の正確さではない）を照合したうえで、両者の交点を採った。さらに設計 plan を
Codex（gpt-6-astra）に premise challenge させ、8 件の反証・欠落をすべて採用した（うち 2 件は一部採用）。手順・交点・
反証の採否・費用の導出は [docs/design/2026-09-14-research-method-redesign.md](../design/2026-09-14-research-method-redesign.md)
に要約した（原本は運用者の harness 側 plan ファイルで repo 外）。

飽和の原因は未測定である。ADR-0001 が固定ドメイン時代の飽和を実測しており、repo 文脈を渡す前から起きていた。
「文脈を渡すから収束する」は反証されていないが、支持もされていない。本 ADR は文脈を渡す方式に戻しつつ、
問いの立て方と run 間の記憶の粒度を変える。

運用者の方針として、「面白さ」や読者の主観を数値化・採点する評価は設計しない。

## Decision

1. **7 line を 1 日 3 本の K-window で輪番する。** `[general] lines_per_day = 3`。`rotation-pick` は非 daily 行から
   `start = ordinal × K mod N` を起点に連続 K 行を選ぶ（K=1 は従来と同位相。7 × 3 で各 line は 7 日に 3 回、
   同日重複なし）。edge line の `daily = true` は外し、輪番に合流する。daily 機構は schema に残す。
2. **各 line の結果を 4 つの内容状態にする。** 呼1 は記事の直後に run receipt `state/<line>/runs/<date>.json`
   （status = `article` / `brief` / `quiet` / `hold`、report、question、reason、reason_code）を書く。
   レポート存在ゲート（ctl-015）は receipt 駆動になる: receipt が無い・不正 → line 失敗。article / brief は
   記事ファイルが必要。quiet / hold は記事なしで成功。全 line が quiet の日も正常終了。quiet / hold で
   `reason_code = fetch_failed` または web 検索 0 回のものは `suspect` として別計上し通知する（失敗にはしない）。
3. **短い文脈から始め、選定後に詳細を読む。** 呼1 は `state/<line>/brief.md`（主題 / 開いた問い / 既知の
   前提 / repo 参照箇所。初回は呼1 が focus から初期化）、問い履歴、`pending.md`、自己シグナルだけを読んで
   候補を立てる。config の `context_files` は選んだ問いの含意を確認するために選定後に読む。config の `focus`
   は主題の説明であり選択条件ではない（「使い道優先」の文言は外す）。
4. **問いの候補を問いの形で自由記述し、履歴の照合を問い粒度にする。** 候補 3〜6 件のうち 1 件は視点変更
   （当事者 / 状況 / 言語・地域 / 隣接）、1 件は広い探索で拾った未使用の観測から。選定は「答えが分かって
   いない度合い」を第一にし、repo での使い道はゲートにしない。past_topics.json の entry に `question` と
   `answer_scope` を加え、同じ問い + 同じ答え = 不採用、同じ問い + 新証拠 = 更新可、同じ topic + 別の問い =
   可、とする。原典が問いの前提を崩したら問いを 1 回まで改訂してよい。
5. **根拠ファイルと原典照合 pass。** 呼1 は記事を支える主張 3〜6 件を `runs/<date>.md`（proposition / 原典 /
   locator / 時点 / evidence_type / 条件・反対材料 / origin_group / provenance / fetch_status）に書く。呼2 は
   fresh context で、clarity 改稿を先に行ってから、全 claim の原典を WebFetch で再取得し、数値・範囲・
   比較対象・話者を原典に合わせて訂正する（合わせられなければ文を削る。帰属表現への言い換えは訂正ではない）。
   取得できない原典はソース節に `(未解決 <日付>)`。結果を `runs/<date>.verify.json` に書き、shell が metrics へ
   `verification` として合算する。呼2 の失敗や verify.json の欠損は `unverified` として通知に出す（fail-open で
   公開は止めない）。呼2 のツールは Read / WebFetch と当該 2 ファイルへの Edit だけ、WebSearch は禁止。
   モデルは `[verification] model`（既定 sonnet）。
6. **機会メモの正本を `state/<line>/pending.md` に置く。** 状態 `pending` / `resolved` / `contradicted` /
   `expired` / `unverifiable`、判定 source、更新条件、期限を持つ。記事末尾の「機会メモ」は読者向けの抜粋で、
   5 行定型（何を / どこで / 失効日 / 判定 source / 更新条件）。playbook は delta 追記のまま、各行に
   `[世界の根拠]` / `[操作上の観測]` / `[暫定判断]` を付け、取消は superseded 注記。watched-sources は
   last-attempt と last-seen を分ける。
7. **本文の固定見出しを撤去する。** frontmatter に `kind`（article / brief）と `question` を加え、本文は
   自由形式の散文（第一文は外部の出来事、含意は条件付き、反対材料を 1 つ）。固定は末尾の「機会メモ」
   「ソース」だけ。article は本文 3,000 字以内で材料に応じて短く、brief は 300〜600 字。lint は `kind: brief` で
   文字数と機会メモの soft check を免除する。
8. **metrics と expect-check を拡張する。** record に `line_states`（article / brief / quiet / hold / mismatch /
   suspect / unverified）と `verification`（supported / partial / unsupported / unverifiable / edits /
   lines_verified）。expect-check に `quiet_rate`、`receipt_count_min`、`unsupported_rate`
   （(unsupported + partial) / (supported + partial + unsupported)）、`unverifiable_rate`、`clarity_ok_rate`。
   log / metrics のラベル `Clarity` / `clarity_pass` は履歴互換のため据え置く。

## Review-when

4 週後（2026-10 中旬）の `/dr-review` で判定する。「面白さ」は判定に使わない。

- `unsupported_rate` が 14 日で 0.2 を超え続ける → 呼1 の根拠ファイルか呼2 の照合が機能していない。verify-golden
  fixture（既知誤りを植えた原稿）を呼2 に当てて見逃し / 過剰修正を確認し、モデルを opus に上げるか照合規則を直す。
- `clarity_ok_rate` が 14 日で 0.8 未満 → 呼2 の WebFetch + 30 turn が予算に収まっていない。WebFetch を外すか
  claim 上限を下げる。
- `quiet_rate` が 0.5 を超え続ける、または `suspect` が繰り返し出る → quiet が隠れ蓑になっている。取得失敗の
  原因（source の到達性）を先に見る。
- `receipt_count_min` < 3 の日が続く、E_PARTIAL が週 2 回以上 → gate か timeout の設計を見直す。
- `total_cost_mean` > 18（導出は design 文書: 呼1 $4.1〜4.7 × 3 + 呼2 $0.7〜1.0 × 3 = $14.4〜17.1 の天井）、または
  完了が 07:00 を越える日が続く（典型 25〜35 分、最悪 210 分 = 08:30） → claim 数・探索枝を減らす。検証を形だけ残さない。
- 運用者が「無関係な記事が増えた」と述べる → 選定前に渡す repo 文脈（brief.md の内容）を増やす。多様性のために
  関連性を後回しにしたことを成功と扱わない。
- モデルまたは Claude Code の更新で、単一 pass で同等の原典照合ができるようになる → 呼2 の分離を再比較する。

## Alternatives Considered

### discovery 号（ADR-0016）を継続する

8 日の運用で運用者が「無関係な話題ばかり」と評価した。repo 文脈を渡さない設計は読者の関心との接続を失う。棄却。

### 直前の状態（ADR-0015 の tree: 輪番 1 本 + edge daily = 毎朝 2 本）へ素のまま戻す

48c8908 の復元がそのまま実行した選択肢で、費用ゼロ。しかし旧方式への不満（似た題材が続く、節構成が冗長、
記事が無い日を失敗扱いにする）がそのまま再現する。復元は本 ADR の起点として使い、上に構造変更を載せる。

### 1 日 1 本または 2 本のまま（K=1 / K=2）

読む量は減るが、各 line の再訪間隔が 7 日（K=1）または 3.5 日（K=2）に延び、運用者が「1 日 5 本は多いが 3 本
くらいを輪番で」と 3 本を選んだ（2026-09-14）。読む量は K でなく内容状態（quiet / brief）と本文長の短縮で
抑える。K は config 1 行で変えられる。

### 探索 / 執筆 / 検証を 3 プロセスに分ける（Codex 版ディープリサーチの案 II）

執筆を別モデルへ渡すと素材圧縮で条件が落ちる（Codex 版自身が弱点として挙げる）。1,000〜3,000 字の記事で
執筆だけを分ける利点は薄い。探索 + 執筆を 1 プロセス、検証 + clarity を fresh context の第 2 プロセスにする
（両報告の交点）。棄却、ただし `unsupported_rate` が下がらない場合は再検討。

### orchestrator–worker（Anthropic の研究 agent 構成）

Codex 版ディープリサーチが Kim et al.（arXiv 2512.08296、180 構成比較）を「逐次課題では multi-agent が 39〜70%
悪化」と要約している（二次情報、原典未照合、2026-09-14）。日次 1 line の解説記事は並列分解できる breadth-heavy な
課題ではない。棄却。

### 段階導入（Claude 版ディープリサーチの推奨: 週 1 は問い生成だけ差し替え、効かなければ次へ）

何が効いたかを分離できる利点があるが、運用者は一括導入を選んだ（2026-09-14）。効果の帰属は Review-when の
指標で事後に見る。

### 読者の主観（面白さ）を採点する評価

運用者方針で採らない。過去にそれで壊れた（memory `feedback_subjective_eval_trap`）。

## Consequences

### Positive

- 更新なし・保留が正常な結果になり、字数を埋めるための記事が減る。
- 問い粒度の履歴で「同じ topic の別の問い」を除外せず、「同じ問いの同じ答え」を弾ける。
- 主要主張が原典で再照合され、不一致は原典に合わせて訂正される。検証結果が metrics に残る。
- 固定見出しの反復が消える。読む量は 3 本 × 最大 3,000 字で、旧 2 本/日より上限は増える — quiet / brief と
  「材料に応じて短く」で実量を抑える設計で、上限で読ませる設計ではない。

### Negative

- state ファイルが line ごとに 3 つ増える（brief / pending / runs）。呼1 の Step 6 が長くなる。
- 呼2 の費用と時間が増える（WebFetch + 30 turn、timeout 1200 s）。3 line の最悪所要は 呼1 1500 s × 2 + 呼2 1200 s
  = 70 分 × 3 = 210 分（05:00 起動で 08:30）。典型は 25〜35 分。
- 4 種の state 成果物（receipt / 根拠ファイル / verify.json / pending.md）が line ごとに増え、戻すときは gate と
  metrics の両方を巻き戻す必要がある（復元コスト）。
- past_topics.json の既存 entry には `question` / `answer_scope` が無い。reader は title で代替表示し、遡及付与は
  しない。
- **state は検証前の版である**: 呼2 が主張を訂正・削除しても past_topics / pending / receipt は呼1 が書いた
  ままになる（呼2 は state を触らない設計）。次回の呼1 が playbook の delta で吸収する。
- receipt を記事直後に書く順序のため、receipt 後・state 更新前に timeout した run は成功扱いになり state が
  更新されない（受容したリスク。retry skip が二重実行を防ぐ）。
- 本文見出しの撤去と問い候補の自由記述は**編集判断**であり、Price of Format（arXiv 2505.18949）の実証対象
  （instruction tuning の構造化テンプレート）とは異なる。効果は Review-when で見る。
- 旧 commit trailer `total_cost_mean <= 13`（beb554a）は設計上 NOT_ACHIEVED になる。

### Neutral / Follow-ups

- verifier の見逃しは自己申告では測れない。`tests/fixtures/verify-golden/` に既知誤りを植えた原稿を置き、
  試走時と `/dr-review` 時に呼2 を手動で当てる（launchd には入れない）。
- x-draft skill はファイル名 `{date}_{track}_{slug}.md` を前提にしており、本 ADR で再び整合する。
- discovery 号の code と protocol は tree から削除した（記録 7877a11、削除 48c8908）。ADR-0016 は記録として残す。
- 実装は同日の commit 群で行う: prompt / template / config / docs は判断 session が main で、shell / python / tests は
  build session が branch `task/rd-pipeline` で書き、検収後に ff-merge する。merge 後に本節へ commit を追記する。
