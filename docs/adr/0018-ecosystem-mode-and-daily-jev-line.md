# ADR-0018: 接地 repo を持たない ecosystem mode を追加し、Jev エコシステム観測 line を daily で新設する

## Status

Accepted。[ADR-0008](0008-per-repo-in-context-research.md) の「1 line = 1 repo、cwd = target_repo」に、repo を持たない
第 2 の実行形を足す（0008 の Consequences が「復活させる場合は per-repo 機構とは別の実行形を設計し直す必要がある」と
書いた、その実行形）。[ADR-0017](0017-three-line-window-content-states-and-verification-pass.md) の Review-when の
費用・所要時間の閾値を 4 line 前提へ再基準化する。[ADR-0011](0011-daily-line.md) の daily 機構は変更せずに使う。
旧 ADR 側の注記は 0008 / 0017 に付けた。

## Date

2026-09-21

## Context

TypeSafe AI の System One モデル Jev は 2026-09-21 時点で early access にある（typesafe.ai を同日取得して確認）。
公開から日が浅く、同日の Web 検索（query: `awesome jev typesafe "System One" model github`）は Jev の利用例を集めた
awesome list を 9 件返し（GitHub の hellogumbo / kraayenjon / yibie / cobanov / AnotiaWang の各 `awesome-jev`、
Anil-matcha/awesome-jev-by-typesafe、AbdelStark/awesome-typesafe、lukstei と keltokhy の `awesome-jev-typesafe`）、
うち https://github.com/cobanov/awesome-jev は取得時点で約 155 件を掲載し、最終更新は 2026-09-20 だった。運用者は、この誕生直後のエコシステム — Jev や型付き確率判断を
制御面の中心に置くエージェント基盤、SDK、plugin、近接実装 — を毎日観測し、評価の定まっていない実装を早く見つけたい。

既存の 7 line はこの目的に合わない。ADR-0008 以降の line は研究 repo を cwd にして走り、目的関数は「repo に関係する
外部の動向を 1 つ解説する」（[ADR-0014](0014-trend-explanation-report.md)）である。Jev line の観測対象はエコシステムの変化
そのもので、運用者の harness や研究 repo への適用可能性を選定条件にすると、発散的な観測が「自分のツールに使えるか」へ
収束する。運用者はこの line で harness・研究 repo の方針や課題を読み込まないことを明示的に求めた。

現行コードは repo なしの line を実行できなかった。`dr_pipeline.py` の `_track_rows` は `[[tracks.<x>.repos]]` の無い
track に行を出さず（エラーも出さず黙って消える）、`daily-research.sh` は `cd "$TARGET_REPO"` を前提にし、
`prompts/repo-research-protocol.md` と `templates/report-template.md` は「この research repo」を前提にした文言を持つ。
加えて `claude -p` は cwd に関係なく運用者の `~/.claude/CLAUDE.md` と rules を自動ロードする（2026-09-21 の probe で
確認）。同じ probe で、`claude` CLI の `--safe-mode` がこれらを外し、`-p` と `--append-system-prompt-file` は
safe mode でも有効であることを確認した。probe は `claude -p "<ロード済みの instruction ファイルの列挙と、system prompt に
目印の文字列があるかを答えよ>" --model haiku --max-turns 1 --append-system-prompt-file <目印 1 行のファイル>` を
`--safe-mode` の有無で 1 回ずつ実行したもので、フラグ無しは `~/.claude/CLAUDE.md` と rules の各ファイルを列挙し、
フラグ有りはロード済みファイル無し・目印は両方で有りと答えた。`claude --help`（2026-09-21）は safe mode を
「CLAUDE.md, skills, plugins, hooks, MCP servers, custom commands and agents … disabled」「Auth, model selection,
built-in tools, and permissions work normally」と説明する — **permissions は safe mode の対象外**で、user settings の
`defaultMode: auto` も project settings も通常どおり効く。

repo を持たない line には失敗の先例がある。[ADR-0007](0007-return-to-four-repo-concept-reinforcement.md) は自由探索
line を「出力がユーザーの関心から構造的に遠ざかり続けた」として全廃し、[ADR-0016](0016-discovery-first-edition.md) の
repo 文脈なしの日刊号は 8 日の運用で「無関係な話題ばかり」と評価されて ADR-0017 で退役した。どちらも主題を固定しない
自由探索だった。なお 0016 の Decision 3 は「専用作業ディレクトリから `--safe-mode` で起動」する隔離を既に採っていた
（実装は 0017 の復元で削除済み）。0016 の退役理由は主題の不固定であって隔離の形ではなく、本 ADR はその形を
固定主題の line に使う。

## Decision

1. **track の config key `mode` を追加する**。値は `"repo"`（既定、省略可）と `"ecosystem"`。`_load_tracks` が enum を
   検証し、`mode = "ecosystem"` の track に `repos` または `context_files` があれば ValueError にする — ecosystem line は
   repo 文脈を要求できないことを schema で強制する。`_track_rows` は ecosystem line に `line<TAB>line<TAB>`（第 3 列が空）の
   1 行を出す。3 列の TSV 形と、daily フラグ・輪番の扱いは変えない。
2. **実行形は mode から決める。line 名では分岐しない**。`daily-research.sh` は line ごとに
   `config-get tracks.<line>.mode` を読み、ecosystem なら 呼1 を cwd = `state/<line>/`、
   `--append-system-prompt-file prompts/ecosystem-research-protocol.md`、`--safe-mode` 付きで実行する。
   書き込み許可（vault のレポート dir / `state/<line>/` / `past_topics.json`）、モデル・timeout・リトライ、
   receipt gate（ctl-015）、4 内容状態、report lint（ctl-016）、呼2、metrics は repo line と同一のコードを通す。
   `--disallowedTools` は repo line と同じ `Bash,Task,NotebookEdit` に、ecosystem line だけ次を足す:
   `Edit(state/<line>/.claude/**)` / `Edit(state/<line>/CLAUDE.md)` / `Edit(state/<line>/.mcp.json)`（cwd が model の
   書ける場所になるため。claude は cwd 直下の `.claude/settings.json` を project settings として読むので、web 由来の
   注入が `permissions.allow` を書くと翌朝の書き込み先が広がる — 2026-09-21 の security review の指摘）と、
   `Read(~/.claude/**)` / `Read(~/.codex/**)`（運用者の harness を permission 層でも読ませない。safe mode で user hook が
   外れる分の代替を兼ねる）。いずれも絶対パスで渡す。repo line に渡るプロンプト文字列と実行引数は変えない。
   > **注記（2026-10-31, [ADR-0019](0019-wide-line-safe-mode-static-state.md)）**: 書き込み許可は vault のレポート dir・`pending.md`・`watched-sources.md`・`runs/**` に狭め、`past_topics.json` を外した（ADR-0019 Decision 4）。`--safe-mode` と `~/.claude`・`~/.codex` の Read deny は全 line 共通になった（同 Decision 2）。
3. **ecosystem line 用のプロトコルとテンプレートを別ファイルで持つ**。`prompts/ecosystem-research-protocol.md` は
   既存プロトコルと同じ契約（receipt 形式、根拠ファイルの表、4 内容状態、末尾固定 2 節、完了報告）を持ち、次を変える:
   目的関数を「エコシステムで前回報告以降に起きた意味のある変化」にする / 探索を毎回 2 経路（A = watchlist の差分確認、
   B = watchlist に無い候補の広い探索）に分けて両方実行する / 重複を topic 名でなく「前回報告後の変化」で判定する
   （既存の `question` / `answer_scope` の問い単位履歴はそのまま使う）/ Step 3b（選定後に repo を読む）を持たない /
   運用者の既存ツールへの適用可能性を選定条件にも本文の着地にも使わない。プロトコルは mode の汎用品として書き、
   特定エコシステムの固有名は config の `focus` / `sources` と state に置く。`templates/report-template-ecosystem.md` は
   同じ frontmatter と同じ固定 2 節を持ち、本文に固定見出しを足さない。既存の `repo-research-protocol.md` と
   `report-template.md` は変更しない。
4. **watchlist は既存の `state/<line>/watched-sources.md` に表として持つ**。列は 名前 / canonical URL / 種別 / 初出日 /
   last-attempt / last-seen / 最後に報告した意味のある変化 / 状態（active / watch / hold / stalled / archived）。エントリは
   削除せず状態で表す。新しい永続形式と parser は作らない — model が読み書きする markdown のまま。
5. **line `jev` を `mode = "ecosystem"`、`daily = true` で新設する**。毎朝、輪番 window の 3 本の後に 1 本走り、1 日 4 本に
   なる。非 daily 行数は 7 のままで、輪番の本数・順序・位相と `lines_per_day` の意味は変わらない。4 内容状態の目安は
   article = 新しい基盤・重要な OSS・実測を伴う動き、brief = 小さいが意味のある release・plugin・実験・issue、
   quiet = 意味のある新規動向なし、hold = 有望だが一次ソースや動く実装を未確認。line 定義（focus / sources）は
   gitignore された運用者の `config.toml` に置き、公開 repo は `config.example.toml` の `example_ecosystem_line` が
   形だけを示す。
   > **注記（2026-10-31, [ADR-0019](0019-wide-line-safe-mode-static-state.md)）**: jev line は廃止した（2026-10-19 から輪番に入っていた）。ecosystem mode（Decision 1〜4）は広域 line `wide` の器として有効（ADR-0019 Decision 1）。
6. **ADR-0017 の費用・所要時間の閾値を 4 line 前提へ再基準化する**。`total_cost_mean` の閾値を 18 から 24 にする
   （0017 の導出「呼1 $4.1〜4.7 × 3 + 呼2 $0.7〜1.0 × 3 = $14.4〜17.1 の天井」を 4 line に当てると $19.2〜22.8、
   同じ丸め方で 24）。最悪完了は 0017 の「最悪 210 分 = 08:30」（1 line あたり 70 分）を 4 line に当てて
   280 分 = 09:40。運用 docs（RUNBOOK ほか）は 3 line の最悪を約 195 分（1 line あたり 65 分）と書いており、
   docs 側は同じ基準で約 260 分と書く — どちらも見積もりで、実測ではない。0017 の Review-when が判定に使うのは
   完了時刻（07:00 を越える日が続くか）で、この 2 つの見積もりは判定に使わない。同じ節の `receipt_count_min` < 3 は
   4 line 前提で < 4 と読む（当日の実行 line 数 = `lines_per_day` + daily line 数）。`quiet_rate` は metrics が line 別の
   内訳を持たないため jev の quiet も同じ分母に入る — 0.5 を越えたら、先に jev の receipt の quiet 日数を引いて
   repo line だけの率を見る（jev の quiet は本 ADR では正常な結果で、jev 自身の条件は下の Review-when が持つ）。

## Review-when

- jev line の `quiet` が 14 日のうち 10 日以上になる（`state/jev/runs/` の receipt の `status` を数える。判定器は
  receipt-read、対象は jev line 固定）→ エコシステムは毎日追うほど動いていない。`daily = true` を外して輪番に入れるか、
  line を止める。
- jev line のレポートで、watchlist の「最後に報告した意味のある変化」が変わっていないエントリの再掲載を、30 日の
  うちに運用者が 2 回指摘する（指摘は `/dr-review` の記録に残す。プロトコルの Step 3 を書き換えたら計数をやり直す —
  判定対象が変わるため）→ 変化単位の重複判定が効いていない。プロトコルの Step 3 を直すか、判定を機械化する。
- 運用者が `/dr-review`（週 1 目安）で jev line を「無関係な話題ばかり」「関心から遠い」と評価する（ADR-0007 /
  ADR-0016 と同じ失敗形）→ 固定主題でも repo 文脈なしでは関心との接続を保てないことになる。ecosystem mode 自体を
  再検討する。
- `total_cost_mean` > 24、または完了が 07:00 を越える日が続く → jev を輪番へ移すか、経路 B の query 数を減らす。
- Jev が一般提供になり評価の定まった実装が揃う、または TypeSafe がサービスを終了する → 「誕生直後の観測」という前提が
  消える。line の focus を書き直すか line を止める。
- `claude` CLI の更新で `--safe-mode` が廃止される、`-p` や `--append-system-prompt-file` と両立しなくなる、または
  permission フラグを無効化するようになる → ecosystem line の 呼1 が失敗するか隔離が消える。E2E mock は引数の有無しか
  見ないので、jev line だけが連日 gate に落ちたら最初にここを疑う。

## Alternatives Considered

### jev line を作らず、Jev の周辺は運用者が手で追う（現状維持）

費用も実装もゼロ。棄却: 運用者が毎日の自動観測を求めた（2026-09-21 の依頼）。手で追う場合、既知候補の差分確認と
未知候補の探索を毎回両方行うこと、何をいつ報告済みかを変化単位で記録することは、運用者の記憶に依る。既存の
line state（watched-sources / pending / 問い単位の履歴）と receipt gate がこの記録と規律を既に持っており、line として
載せれば追加の仕組みを作らずに使える。費用に見合わないと分かった場合の出口は Review-when の quiet 条件が持つ。

### jev を repo line にして、空の placeholder repo を target_repo に置く

desire-frontier / edge-frontier の先例（資料中心の軽い repo）と同じ形で、コード変更はゼロで済む。棄却: 観測対象の
ない repo を「接地」と呼ぶことになり、プロトコルは「repo との接点」「repo の doctrine」を語り続ける。目的関数の違い
（repo に関係する動向 vs エコシステムの変化そのもの）が config にもプロンプトにも現れず、`~/.claude` の自動ロードも
残る。

### daily-research 自身を cwd にする

[ADR-0013](0013-edge-daily-line.md) が edge line で一度棄却した案（オーケストレータの運用文脈は研究上の前提・問いを
持たない）。今回は「repo 文脈が要らない」ので棄却理由の半分は当たらないが、cwd が project root だと Glob / Grep の
既定範囲に `config.toml`（他 line の focus）と他 line の state が入る。cwd = `state/<line>/` のほうが、手元の文脈を
line-local state に限るという要件に直接対応する。棄却。

### 既存プロトコルに mode 別の条件分岐を書き込む

ファイルが 1 つで済み、共有契約の二重管理が無い。棄却: 既存 7 line の system prompt に ecosystem 向けの文言
（watchlist、二経路、適用可能性を見ない）が入り、既存 line への文言漏れを防ぐという要件を守れない。二重管理の
drift は、`tests/test-daily-research.bats` が両プロトコルに同じ assertion を当てることで検出する。

### line 名 `jev` で shell を分岐する

最小の変更量。棄却: 2 本目の ecosystem line を足すたびにコードを触ることになり、config 駆動という現行の設計
（line 名・line 数はコードに現れない）を壊す。

### 輪番に入れる（daily にしない）

費用は増えない（7 日に 3 回 → 8 line だと 8 日に 3 回）。棄却: 公開直後で変化の速い対象を 2〜3 日おきに見ると、
経路 A の差分確認が「前回以降」を取りこぼしやすく、早期発見という目的に合わない。Review-when の quiet 条件を
踏んだら、この案へ移る（未決 — 再訪条件: quiet が 14 日中 10 日以上）。

### `--safe-mode` を使わず、プロトコルの文言だけで harness を読ませない

CLI のフラグに依存しない。棄却: `~/.claude/CLAUDE.md` と rules は Read しなくても自動で context に入る
（2026-09-21 の probe）。文言では外せない。

## Consequences

- repo を持たない line が config だけで足せるようになる。2 本目以降の ecosystem line は `[tracks.<x>]` の追記と
  `state/<x>/` の初期化で済む。
- 既存 7 line の輪番・プロンプト・実行引数は変わらない（pytest が 14 日分の window の一致を、E2E mock が repo line の
  cwd / protocol / 引数の不変を検査する）。
- 呼1 のプロトコルが 2 ファイルになり、共有契約（receipt・根拠ファイル・固定 2 節・4 状態）を変えるときは両方を直す
  必要がある。静的テストが検出するのは列挙した文字列の欠落だけで、意味のずれは検出しない。
- 1 日の費用と所要時間が約 4/3 になる。運用 docs の 3 line の目安（$12〜15/日、典型 25〜35 分）を 4/3 倍して
  典型 $16〜20/日・35〜45 分（33〜47 を丸めた）。Decision 6 の $19.2〜22.8 は同じ 4 line の天井で、別の量。実測は
  初週の `metrics.jsonl` で確認する（本 ADR の時点では未測定）。
- 2026-09-21 以降の metrics は 4 line 合算になり、`total_cost_mean` / `pass2` / `quiet_rate` は日付で期間を分けて読む。
  巻き戻しは config の `[tracks.jev]` を消すだけで済む（mode の機構は使う line が無ければ何もしない）が、系列の
  断絶は残る。
- read の permission 層は部分的。`~/.claude` と `~/.codex` は deny するが、他 line の state・運用者の研究 repo・
  `config.toml` の Read は deny していない。そこを読まないことはプロトコルの文言と cwd に依る（`--allowedTools` の
  `Read` が path 制限を持たないのは repo line と同じ）。
- safe mode は user hook を外す。Bash 系の hook は両 mode とも Bash 自体が deny なので元から効いておらず、実効的に
  外れるのは Read 系の hook だけで、`Read(~/.claude/**)` の deny がその範囲を覆う。境界は両 mode とも
  `--disallowedTools` であり、safe mode は隔離の一部であって権限の境界ではない。
- watchlist は model が保守する markdown で、形式崩れ・状態語彙の逸脱は機械検査されない。parser を増やさない判断の
  対価で、崩れは `/dr-review` の読みで拾う。
- プロトコルの質（二経路が両方走るか、変化単位の重複判定が効くか）は mock では検証できない。最初の実測は初回の
  本番 run になる。
- ecosystem line は `--safe-mode` という CLI の挙動に依存する。呼2 は従来どおり project root で safe mode なしに走る
  （呼2 は研究文脈を持たず、対象ノートと根拠ファイルだけを読む）。
  > **注記（2026-10-31, [ADR-0019](0019-wide-line-safe-mode-static-state.md)）**: `--safe-mode` と `~/.claude`・`~/.codex` の Read deny は repo line と呼2 にも広げた（ADR-0019 Decision 2）。上の「Read 系の hook が外れる範囲を deny が覆う」は全 line・両呼び出しで成り立つ。`[billing] env_file` の親 dir の Read も共通 deny に足した。
