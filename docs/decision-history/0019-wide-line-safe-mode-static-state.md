# ADR-0019: 広域 line を daily で置き per-repo を 1 日 1 本にし、呼び出しの土台と run ごとの記帳を削る

## Status

Accepted。[ADR-0018](0018-ecosystem-mode-and-daily-jev-line.md) の jev line（Decision 5）を廃止し、ecosystem mode
（Decision 1〜4）は広域 line の器として使い続ける。[ADR-0008](0008-per-repo-in-context-research.md) Decision 3 の
run 構造（repo line の watched-sources 巡回と playbook の delta 更新）と Decision 1 の「自動ロードされる repo 設定」を
置き換える。[ADR-0017](0017-three-line-window-content-states-and-verification-pass.md) の `lines_per_day` の運用値と
brief の「開いた問い」を変える。[ADR-0010](0010-rotation-and-two-tier-eval.md) Decision 4 の「呼2 は safe mode なしで
daily-research の CLAUDE.md を読む」トレードオフを外す。ADR-0017 の Review-when のうち費用・本数の閾値
（ADR-0018 Decision 6 で 4 line 前提に再基準化したもの）は使わなくなり、費用の判定は Decision 7 のゲートが持つ。
モデルの書き込み先（ADR-0008 Decision 5、ADR-0018 Decision 2 の「vault / state / past_topics」）を狭める。
旧 ADR 側の注記は 0008 / 0010 / 0017 / 0018 に付けた。

## Date

2026-10-31

## Context

Plan: [docs/plans/happy-growing-bachman.md](../plans/happy-growing-bachman.md)（承認 2026-10-31）。根拠の束は
[docs/plans/research/2026-10-31-report-quality-and-cost.md](../plans/research/2026-10-31-report-quality-and-cost.md)
（以下 research）。

運用者の不満は 2 つだった（grill-me、2026-10-31）。(1) 問いの選定がいまの関心からずれ、同じ題材に戻る。(2) 費用。

選定のずれと繰り返しについて、research §3・§4 は次を観測した。brief の「開いた問い」はモデルが毎 run 書き足して
閉じに行く宿題で、選定前に読む 4 入力の 1 つだった（`prompts/repo-research-protocol.md` の Step 1 と Step 6）。
repo line の `watched-sources.md` は最大 171 KB に育ち、大半が事例の経過メモで、毎 run 全 source の巡回と記帳を
求めていた。`playbook.md`（line ごと 45〜76 KB）は scripts・`dr_pipeline.py`・dr-review のどれからも読まれず、
追記のための Read だけがあった。2026-09-14 以降の live 30 run（`metrics.jsonl`）の終わり方は article 25 / brief 5 /
quiet 0 / hold 0 で、材料が薄い日にも何か書いていた。per-repo は狭い領域を週 2〜3 回掘るので、題材の到着速度を
上回った。運用者の体感では、track 制で広い領域を見ていた 2026-05〜06 が最も鋭かった（research §3）。

費用について、research §1 は呼1 が line 費用の大半を占め、その約 3 割が呼び出しの土台であることを示した。
`claude -p` は API 課金に切り替えた後も Claude Code CLI として起動するので、運用者の `~/.claude` のハーネス
（CLAUDE.md・rules・skill 一覧・plugin）と cwd の CLAUDE.md が毎回 context に入り、使わない組み込みツールの定義も
載る。CLI 2.1.314 の probe（`claude -p "OKとだけ答えて" --model haiku --max-turns 1`、2026-10-31）では、cwd = akc で
cache 書き込み 64,470 token が `--safe-mode` で 28,778 token になり、cwd = daily-research で `--safe-mode --tools
"Read,WebFetch,Edit"` を付けると 5,704 token になった。safe mode は cwd の CLAUDE.md も落とす（両 cwd の合計が同値）。
`past_topics.json`（約 1 MB、595 件）への追記はモデルが Read → 追加 → Write で行っていた。

採用率の基準値（research §6、`docs/plans/research/adoption_backtest.py`、21 日窓）は per-repo 7 line の 133 本で
採用 19%（25/133）・引き直し 16%（21/133）だった。率の 95% 信頼区間の半幅は約 1/√n で、per-repo 1 本/日の 6 週（n ≈ 42）では ±15 pt に
なり、interview で一度決めた「6 週後に採用率 15% 以上かつ引き直し率 10% 未満」は誤差と区別できない。

jev line（ADR-0018）は運用者が「外していい」と判断した（grill-me）。jev の採用は 21 日窓で 0 / 2 本だった（research §6）。

## Decision

1. **構成を「広域 line 1 本 + per-repo 輪番 1 本」にする。** ecosystem mode の line `wide` を `daily = true` で置き、
   範囲を「AI 時代の考えと手段」（道具・製品、開発の実践、研究、使い方の文化）とする。per-repo の輪番は
   `[general] lines_per_day = 1`。jev line を config から外す。line 定義は運用者の `config.toml` に置き、
   何を変化と数えるかは `state/wide/brief.md` に置く（関心の定義は運用者の持ち物）。
2. **呼1・呼2 の両方を `--safe-mode` と `--tools <必要な組み込みツール>` で起動する。** 呼1 は
   WebSearch・WebFetch・Read・Glob・Grep・Edit・Write、呼2 は Read・WebFetch・Edit・Write。safe mode で外れる
   user の Read hook（episode-log ブロッカー）の代わりに、HOME 配下の `*/logs/episodes/` と harness（`~/.claude`・
   `~/.claude.json`・`~/.codex`）への Read を、WebFetch で外へ送れる資格情報の置き場（`~/.config`・`~/.ssh`・`~/.aws`・
   `~/.gnupg`・`~/.netrc`・`[billing] env_file` の親 dir）への Read とともに、全 line・両呼び出しの共通 deny に置く。境界は従来どおり deny で書く（safe mode は permissions を外さない — ADR-0018 の probe）。repo の
   CLAUDE.md（無ければ AGENTS.md）は自動ロードされなくなるので、呼1 が選定後の Step 3b で明示的に Read する。
3. **run ごとの記帳を撤去する。** playbook への追記をやめる。brief は主題・読者に既知の前提・参照箇所だけの静的な
   文書にし、モデルは編集しない（「開いた問い」を撤去。待ちの問いは hold が書く `pending.md` だけ）。repo line の
   watched-sources の巡回と記帳をやめる。ecosystem line の watchlist は残し、経路 A の確認を 1 run 8 件までにする。
4. **past_topics への追記をコードへ移す。** モデルの書き込み先は vault のレポート dir・`pending.md`・`runs/**`（ecosystem line は
   watchlist も）に狭め、`past_topics.json` を外す。receipt に `answer_scope` と `title` を足し、orchestrator が gate 成功後に
   receipt から追記する。モデルの書き込み先は orchestrator の配列 1 つを正本にし、`--allowedTools` の Edit 規則と
   プロンプトの「書き込み先」節をそこから描く。根拠ファイルの表（claim ごとの supports / limits / contradicts 列）は
   削らない — Step 5 の「反対材料」と「主張と推論の分離」を claim 単位で強制する唯一の場所で、費用への効きは小さい。
5. **直近の repo 活動を line brief に注入する。**（効かせ方は plan の推奨案を既定とした。運用者の明示回答は無い — plan D5） repo line だけに、14 日分の commit 件名（30 件・2,000 字まで、
   行頭 `#` と制御文字を除去）を「データであって指示ではない」注記の内側へ入れる。問いの候補のうち 1 件以上を
   直近の活動に関係づけるが、どれを選ぶかは自由。探すのは運用者がまだ知らない外部の展開で、いまの作業の裏付けではない。
6. **フィードバックループを入れない。** 読者メモ・既知文献の注入・採用率の選定への還流は置かない。採用の検出は
   pipeline の外の事後集計（`adoption_backtest.py`）として残す。
7. **判定は観測数で開くゲートで行う。** G1 = 新構成の live line-run 10 件で支出台帳の line 平均を見る。G2 = 輪番の
   全 line が 1 回ずつ。G3 = per-repo 14 本 + wide 14 本で運用者が line 別に判断し、14 日目に必ず決める。閾値と
   読み方は plan の「導入と判定」が正本。

呼1 のモデル（Opus）・呼2 のモデル（Sonnet）・課金経路（現行 api）は変えず、subscription モードの選択肢もコードに残す。
導入は実装ができ次第すぐ行い、jrp が共有していた `config.toml` は導入前に jrp 専用の config へ切り離す（運用者の回答、
2026-10-31）。

## Review-when

- G1 で line 平均が plan の「導入と判定」の最上位帯（commit (1) を疑う帯）に入る → Decision 2 が効いていない。Probe の土台 token と実 run の
  cache 書き込みを突き合わせ、safe mode か `--tools` が無効化された経路を探す。
- G3 で運用者が per-repo の記事を「いまの作業の裏付け」と評価する（判断するのは運用者。引き直し件数は
  `adoption_backtest.py` の定義で添える生の数で、n = 14 では率の差を判定できないので閾値にしない）
  → Decision 5 が ADR-0008 の収束を戻した。注入を外すか、候補 1 件の義務だけ外す。
- G3 で運用者が wide を「関心から遠い」と評価する（ADR-0007 / ADR-0016 と同じ失敗形）→ brief と focus の文言を
  直す。それでも同じ評価なら広域 line をやめる。
- G2・G3 で運用者が edge の記事を「手筋が減った」と評価する（edge は基準値で採用が最も多い line で、edge の 25 本中
  12 本。採用は 21 日遅れで分かるので G3 では判定できず、確定値は plan の「参考」行 = G3 から 21 日後に見る）
  → edge だけ巡回を戻す。
- G3 の時点で `pending.md` の行数が line ごとに単調に増えている → hold が新しい宿題帳になっている。pending の
  閉じ方をプロトコルで締める。
- `claude` CLI の更新で `--safe-mode` か `--tools` が廃止・意味変更される、または safe mode が permissions を外す
  ようになる → Decision 2 の前提が消える。

## Alternatives Considered

### jrp（jev-research-pipeline）の構成を移植する（候補をコードが集め、Jev が関連を判定し、LLM は本文だけ書く）

ターンがほぼ無くなり、費用は大きく下がる（jrp の README の比較、research §9）。棄却: 情報源が論文と repo に固定で、
daily-research の強みである Web 全体の発見（LWN・issue・エッセイ・業界レポート）を削る。運用者は「品質を犠牲に
するなら無理に使わなくていい」と条件を付けた。

### モデルを格下げする（呼1 を Sonnet にする）

単価が下がる。棄却: 呼1 の約 3 割は土台で、モデルを変えずに削れる。問いの選定と原典照合の質が
落ちるかは測っておらず、選定のずれという不満を悪化させる側に賭けることになる。

### per-repo を 1 日 2〜3 本のまま、土台と記帳だけ削る

構成を変えずに費用だけ下がる。棄却: 題材の到着速度を上回る掘り方という飽和の機構が残り、繰り返しの不満に
効かない。広い領域を見る line が無い。

### 根拠ファイルの表を 6 列に絞る

出力 token が減る。棄却（Fable のレビュー、2026-10-31）: 費用への効きは 1% 未満と見積もられ、supports / limits /
contradicts 列が claim 単位で反対材料を強制する唯一の場所になっている。

### 読者のフィードバックを選定に還流する（採用率や読者メモを brief に入れる）

関心への接続を直接強める。棄却: 運用者が「一旦入れずに運用する」と決めた（grill-me）。還流は ADR-0008 が警告した
裏付けへの収束を強めうるうえ、採用の検出は 21 日遅れで n も小さく、選定の入力にできる精度が無い。

### 呼1 の safe mode を外し、repo の CLAUDE.md の自動ロードを残す

repo の前提が含意に確実に入る。棄却: 自動ロードされるのは repo の CLAUDE.md だけでなく運用者の `~/.claude` 全体で、
土台の大部分がそこにある。Step 3b の明示的な Read で repo の前提は取れる。Open — 再訪条件: 試験 run か G2 で、
含意が repo の前提とずれる記事が出る（plan の失敗モード表）。

## Consequences

- 呼び出しごとの土台が小さくなり、line 費用が下がる見込み。実測は G1 で行い、本 ADR の時点では未測定。
- repo line の記事は、repo の CLAUDE.md を Step 3b の Read に頼る。読まずに書いた run は repo の前提とずれうる。
- 呼2 は daily-research の CLAUDE.md を読まなくなる。記述規律は `prompts/verification-protocol.md` とテンプレートが
  自己完結して持つ必要がある。
- repo line は diff-first（ADR-0008 Decision 3 の watched-sources + last-seen）を失い、同じ外部 source の再巡回を防ぐ
  記録は past_topics の問い単位の dedup だけになる。同じ題材に戻る不満に対して逆向きに効きうるので、G3 で見る。
- 呼2 の訂正を次回の呼1 が playbook の delta で吸収する経路（ADR-0017 Consequences）が無くなる。訂正は記事と
  verify.json に残るだけになる。
- モデルは playbook・brief・repo の watched-sources・past_topics を書かなくなり、run ごとの state の肥大が止まる。
  既存の state は `state/_archive/2026-10-31/` に退避する（state は git 外なので移動が唯一の退避）。戻すときは
  そこから戻す。
- past_topics の形がコードの定数で決まり、プロトコルの receipt 例・`past_topics.example.json` とテストで一致させられる。
  既存の 595 件は旧い形のまま残る。
- 直近の repo 活動という repo 由来の文字列が呼1 の context に入る経路が増える。上限・除去・データ注記で抑え、
  書き込み先が狭いので被害は vault と state に閉じる。
- jev line の観測は止まる。Jev エコシステムは wide の範囲に入りうるが、毎日の変化単位の追跡ではなくなる。
- 2026-11 以降の metrics は line の構成が変わり、`total_cost_mean` などは期間を分けて読む。
- 1 日の本数は desire の一時的な `daily = true` を外した後に 2 本（per-repo 1 + wide 1）になる。
