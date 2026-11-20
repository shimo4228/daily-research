# 運用手順書

> daily-research 自動化システムの運用手順。

## デプロイ

### 初期セットアップ

```bash
# 1. プロジェクトに移動
cd /path/to/daily-research

# 2. スクリプトに実行権限を付与
chmod +x scripts/daily-research.sh
chmod +x scripts/check-auth.sh

# 3. 認証を確認
./scripts/check-auth.sh

# 4. テンプレートから plist を作成 (リサーチ 05:00)
cp com.example.daily-research.plist com.daily-research.plist
# plist を編集: YOUR_USERNAME を macOS ユーザー名に置換

# 5. launchd シンボリックリンクを作成
ln -sf "$(pwd)/com.daily-research.plist" \
       ~/Library/LaunchAgents/com.daily-research.plist

# 6. ジョブをロード
launchctl load ~/Library/LaunchAgents/com.daily-research.plist

# 7. 登録を確認
launchctl list | grep daily-research
```

### 変更後の更新

```bash
# スケジュールやパスを変更した場合は plist をリロード
launchctl unload ~/Library/LaunchAgents/com.daily-research.plist
launchctl load ~/Library/LaunchAgents/com.daily-research.plist
```

設定・プロンプトの変更（`config.toml`, `prompts/*`, `templates/*`）はリロード不要。次回実行時に自動反映される。

### 手動実行

```bash
# launchd 経由
launchctl start com.yourname.daily-research   # plist の Label

# 直接実行 — Claude Code セッション内からも実行できる（lib/env.sh が CLAUDECODE を unset する）
./scripts/daily-research.sh
# テスト用 seam: DR_FORCE_TRACK=<line>（当日の輪番 window 外でも指定 1 line を今日の日付で実行）、
# DR_ONLY_TRACK=<line>（当日担当のうち指定 line のみ）、DR_DATE=YYYY-MM-DD（輪番の日付を固定）
```

## アーキテクチャ

```
daily-research.sh (05:00)
├── ロック取得（flock の mutex の中で判定と mkdir）
├── 課金経路の設定（[billing]: api = env_file の ANTHROPIC_API_KEY か ant のログイン（credential）、subscription = OAuth）
├── 認証 probe（その経路で Haiku を実際に 1 回呼ぶ。呼1・呼2 と同じく --safe-mode）
├── config schema チェック（`dr_pipeline.py tracks`: ADR-0008 以前の旧 schema と、壊れたライン定義 —
│   `repos` を単一 table で書いた、`key` / `target_repo` の無いエントリがある等 — は fail-fast）
├── rotation-pick — 当日担当ラインを決定論選択: 輪番 window（開始 = date.toordinal() × K
│   mod N、そこから連続 K 本。K = [general] lines_per_day、ADR-0010 / ADR-0017）
│   + `daily = true` の全ライン（毎日実行、ADR-0011）
├── 呼1: claude -p, cwd = 担当ラインの target_repo (Opus, --effort は [effort].call1, --max-turns 55,
│   25 分タイムアウト, transient 失敗時リトライ 1 回; 401 は中止)
│   [api モード: ラインの前に支出ゲート（日・月の上限）、呼び出しごとに --max-budget-usd、
│    呼び出しごとの費用を state/api-spend.jsonl に追記。429 とクレジット切れは run を止める]
│   [mode = "ecosystem" のラインは target_repo を持たない: cwd = state/<line>、
│    prompts/ecosystem-research-protocol.md — ADR-0018。--safe-mode は全ラインに付く — ADR-0019]
│   ├── 短い文脈（line brief + state/<line>/brief.md + 問いの履歴 + pending.md）を Read
│   ├── 広い探索（ecosystem ラインは先に watched-sources.md の watchlist を確認）· 問いの候補
│   │   3〜6 件から 1 つ選ぶ（または quiet / hold）· 選定後に context_files を Read ·
│   │   citation ゲート付きリサーチ · 根拠ファイル runs/{date}.md
│   ├── 解説ノート（固定見出しなし。article ≤ 3,000 字 / brief 300〜600 字）を vault に
│   │   Write（quiet / hold の日は書かない）
│   └── run receipt runs/{date}.json を記事の直後に Write · pending.md 更新
│       （ecosystem ラインは watchlist も更新し、表から外した行を watched-archive.md へ移す）
├── ctl-015 レポート存在ゲート（receipt 駆動: receipt 無し / 不正 → 失敗、article・brief は
│   vault の {date}_{track}_*.md を要求、quiet・hold はファイル無しで成功）
│   → past-topics-append が receipt から問いの履歴を past_topics.json に記録
├── 呼2: fresh-context の検証 + clarity (既定 Sonnet, --effort は [effort].call2, --max-turns 30, 20 分タイムアウト,
│   研究文脈なし, Read + WebFetch, Edit は対象ノートと runs/{date}.verify.json のみ,
│   WebSearch は disallow, 失敗は fail-open — 未検証版が残り run は成功のまま, ADR-0017。
│   認証・課金のエラーは呼1 と同じく残りのラインを止める)
│   [前: script が原稿を state/<line>/pre-verify/{date}.md に写す。
│    後: verify-diff が両者を比べて VERIFY_DIFF をログに出す]
├── 呼3（[audit] enabled のときだけ。kind: article だけ）: 照合監査, ADR-0020（既定 Opus, --effort high,
│   WebFetch だけ — 検索も Read も書き込みの道具も持たない。ノートと根拠ファイルは呼び出しごとの乱数の印を付けた
│   区切りの行で挟んで prompt に入れる）
│   ├── 第 1 段（--max-turns 40, 10 分タイムアウト）: 原典と両立しない文だけを候補にする
│   ├── 第 2 段（URL がノートに書かれた候補ごと、最大 5 件。--max-turns 20, 4 分タイムアウト）: 文・第 1 段の
│   │   置き換え文・URL・ノートの公開日を見て、文の誤りを独立に見つけ、置き換え文がそれを直しているかを判定する
│   └── audit-apply（モデルでなくコード）: 両段が食い違いとし、第 2 段が置き換え文を訂正と認めた候補を、
│       文が本文にちょうど 1 回現れ、置き換えが小さな書き換えで、ノートの URL・link・強調・見出しを保ち、
│       書式の記号を足さないときだけ置き換える。状態は state/<line>/audit/{date}.json、監査の前のノートは
│       state/<line>/pre-audit/{date}.md、ログに AUDIT。どの失敗も fail-open — ノートは呼2 の後のまま
├── ctl-016 決定論的レポート lint（固定節 = 機会メモ / ソース、report-template.md に同期。
│   kind: brief は機会メモと文字数の soft を免除）
├── Pass 3: Obsidian wiki ingest（vault 側スクリプト、non-fatal。外側の timeout = ingest 自身の claude の上限
│   （`WIKI_INGEST_TIMEOUT`、無ければ vault 側の既定）+ 余裕の下。`Pass 3 outer timeout: …` として log に出る）
└── metrics.jsonl 追記 (clarity_pass / line_states / verification / event_age_days / effort 含む) + /dr-review 経過日数チェック
```

(07:00 の morning-brief.sh は ADR-0009 で廃止 — レポートは承認を求めない読み物になった)

## 監視

### ログの場所

| ログ | パス | 保持期間 |
|------|------|---------|
| アプリケーションログ | `logs/YYYY-MM-DD.log` | 30日（自動ローテーション） |
| launchd 標準出力 | `logs/launchd-stdout.log` | 手動クリーンアップ |
| launchd 標準エラー | `logs/launchd-stderr.log` | 手動クリーンアップ |

### 日次チェック

```bash
# 今日のログを確認
cat logs/$(date +%Y-%m-%d).log

# レポートが生成されたか確認（config.toml の vault_path を使用）
ls -la "/path/to/your/obsidian/vault/daily-research/"

# launchd ジョブの状態を確認
launchctl list | grep daily-research
# 終了コード 0 = 前回の実行が成功
```

### ヘルスチェック指標

| 確認項目 | コマンド | 期待結果 |
|---------|---------|---------|
| ジョブ登録済み | `launchctl list \| grep daily-research` | 終了ステータス 0 の行 |
| 認証有効 | `./scripts/check-auth.sh` | "OK: Claude authentication is valid" |
| 今日のログが存在 | `ls logs/$(date +%Y-%m-%d).log` | ファイルが存在 |
| ログに成功メッセージ | `grep "Completed successfully" logs/$(date +%Y-%m-%d).log` | マッチあり |
| レポートが生成済み | `ls <vault_path>/daily-research/$(date +%Y-%m-%d)_*` | article / brief で終わったライン数のファイル（quiet / hold のラインはファイルを作らない） |
| receipt が揃っている | `ls state/*/runs/$(date +%Y-%m-%d).json` | 当日*担当*ライン数のファイル（ゲートの判定材料） |
| 検証が走った | `grep "VERIFY " logs/$(date +%Y-%m-%d).log` | article / brief のラインごとに 1 行（`"ran": true`） |
| 当日の内訳 | `grep "Line states:" logs/$(date +%Y-%m-%d).log` | `article=N brief=N quiet=N hold=N` と今朝 / 更新なし / 未検証の内訳 |

### ログメッセージ一覧

| メッセージ | 意味 |
|---------|------|
| `Billing: api (key from …; caps …)` / `Billing: subscription (Max plan OAuth)` | `[billing] mode` が選んだ課金経路 |
| `ERROR: billing setup failed — …` | `[billing]` が不正、または api モードで `env_file` に `ANTHROPIC_API_KEY` が無い（`credential = "env_file"`）か `ant` がトークンを返さない（`credential = "ant"`: `ant auth login --profile <ant_profile>` でログインし直す）。どの呼び出しより前に停止（exit 1） |
| `Auth probe passed` | 実際に呼び出す認証 probe が成功 |
| `ERROR: Auth probe failed (<mode>) — status=… result=…` | probe が失敗（OAuth 期限切れ、または api モードで key の拒否・クレジット不足・429）。ライン実行前に停止（exit 1） |
| `WARN: API spend gate stopped the run (month $… / $…, day $… / $…, need $… per line) — stopping remaining lines` | api モード: 残額があと 1 ライン分に満たない。残りは止め、`Lines not started: …` に名前が出る（通知: `API 支出の上限に達したため、…`） |
| `WARN: API spend gate could not check the caps (the reason is the ERROR line above) — stopping remaining lines` | api モード: 台帳が書けない・読めない（または gate 自体が失敗した）ので、上限を確かめられなかった。理由は直前の `ERROR: … spend …` 行。残りは止め、`Lines not started: …` に名前が出る（通知: `API 支出を確かめられなかったため、…`。上限の文言は使わない） |
| `ERROR: API spend gate failed (rc 2): spend-gate: N unreadable line(s) in …: line K (理由), … — cannot check the caps` | api モード: 台帳を合計できなかったので、推測せずに止めた。`state/api-spend.jsonl` の読めない行のうち先頭 5 件を行番号と理由で名指し、残りは `and N more` と数だけ出す（その行を直すか消す）。`cannot read …` はファイル自体を開けなかった |
| `Lines not started: a, b` | run が始める前に止めたライン（支出の上限、または認証・課金のエラー） |
| `ERROR: Line <track> hit a billing/rate-limit error — aborting remaining lines, no retry` | api モード: 429 またはクレジット残高不足（`E_BILLING`） |
| `WARN: Line <track> reached --max-budget-usd $… — no retry, going to gate` | 呼び出しごとの上限で呼1 が止まった。書けた分でゲートへ進む |
| `API spend: today $… / $…, month $… / $…` | api モード: run 後の `state/api-spend.jsonl` の合計 |
| `ERROR: Another instance is running. Skipping.` | ロックディレクトリ `.daily-research.lock/` を生存中の `daily-research.sh` の process が保持している |
| `ERROR: Could not verify the lock (…). Skipping.` | ロックを確かめられなかったので run を始めなかった（通知は `ロックを確かめられず実行しませんでした`）。括弧の中が理由: mutex を 10 秒で取れない・`python3` の失敗・mutex のファイルかロックディレクトリを作れない |
| `Config schema check passed` | `config.toml` が現行 (ADR-0008) schema に適合 |
| `ERROR: config.toml schema check failed (the reason is on the line above; see config.example.toml)` | `dr_pipeline.py tracks` が `config.toml` を拒否した（旧 schema、line 名の形、`daily` / `template` / `mode` の型、`mode` の未知の値、`mode = "ecosystem"` の line に書いた `repos` / `context_files` / `read_deny`、壊れた `repos` や `read_deny`、`lines_per_day` の値）。理由は直前に log された行にある。どのラインも始めずに停止（exit 1） |
| `ERROR: read_deny could not be rendered (the reason is on the line above) — no line runs without it` | schema check の後で `dr_pipeline.py read-deny` が失敗し、`read_deny` の deny を作れなかった。deny 無しで走らせず、どのラインも始めずに停止（exit 1） |
| `Effort: call1 <level> (model opus), call2 <level> (model <model>) — passed as --effort` | 各呼び出しに渡す `--effort`（`[effort]`、既定はコード）。同じ組を `metrics.jsonl` の `effort` に記録する。実際に走る level はこれより低いことがある（`maxEffortLevel`・組織の上限・model が受けない level） |
| `ERROR: [effort] in config.toml is invalid (the reason is on the line above; see config.example.toml)` | `[effort]` に未知の key か、`low` / `medium` / `high` / `xhigh` / `max` 以外の値がある。理由は直前に log された行にある。どのラインも始めずに停止（exit 1） |
| `Rotation pick: a, b, c (ADR-0010/0017)` | 当日担当ラインの輪番 window 選択結果 |
| `Today's lines: N` | 当日実行するライン数（`lines_per_day` + daily ライン） |
| `=== Line: <track> (<repo パス>) ===` | その repo を cwd にしたライン run の開始（ecosystem ラインは repo を持たず `no target repo` と出る） |
| `Line <track> mode: ecosystem (cwd = state/<track>)` | `mode = "ecosystem"` のライン。state ディレクトリを cwd に、ecosystem プロトコルで走る（ADR-0018）。`--safe-mode` は全ラインに付く（ADR-0019） |
| `SUMMARY Run(<track>): cost=... turns=... duration=...` | ライン run の実行統計（コスト、ターン数、所要時間、トークン数） |
| `WARN: Line <track> failed (..., exit N) — retrying once` | transient 失敗。1 回きりのリトライを開始 |
| `ERROR: Line <track> returned 401 — aborting remaining lines (…)` | run 中に認証が失敗（401 / 403: OAuth 期限切れか key の拒否）。残ラインは中断、完走済みラインの成果は保持 |
| `ERROR: clarity pass returned an auth error — aborting remaining lines` / `ERROR: clarity pass hit a billing/rate-limit error — aborting remaining lines` | 呼2 が同じエラーに当たった。呼1 の後と同じく残りのラインを止める |
| `WARN: Line <track> clarity pass skipped after an auth/billing error — note stays unverified` | そのラインの呼1 がノートを書いた後に認証・課金のエラーで終わった。呼2 は始めない |
| `Line <track> state: <status>` | receipt が申告した内容状態（article / brief / quiet / hold） |
| `Line <track> report gate passed` | ctl-015: そのラインが receipt どおりの成果を残した（article / brief は `{date}_{track}_*.md` が vault に存在、quiet / hold はファイル無しで通過） |
| `WARN: Line <track> past_topics.json append failed — history not recorded` | ゲートは通ったが、receipt から問いの履歴を追記できなかった。ラインは成功のままで、run 開始時の `past_topics.json.bak` が残る |
| `Line <track> pending.md: items A→B, chars C→D` | そのラインの `pending.md` の項目数と字数の、呼1 の前とゲート通過後（見出し・太字で始まる箇条・表の行を項目と数える） |
| `WARN: Line <track> pending.md の項目が <state> の run で N 件増えた (…)` | hold 以外の run が、ノートの日付付き締切の機会の数より多く `pending.md` に項目を足した。プロトコルが項目を足してよいとするのは hold の問いと日付付き締切の機会だけ。log だけで、ラインは成功のまま |
| `receipt-event-date: WARN … — counted as unknown` | receipt に `event_date` が無い（古い receipt）か、run の日付以前の暦日でない。ラインは成功のまま、不明として数える |
| `Line <track> event_date: <YYYY-MM-DD\|unknown>` | article / brief のときだけ: ノートの中心の出来事の日付で、receipt の `event_date` から取る（H17、新しさの計測）。metrics の `event_age_days` に記録する。ゲートにも選定にも効かない |
| `WARN: report gate failed for line <track> — no <date>_<track>_*.md (ctl-015)` | receipt が article / brief なのにレポートが無い — 失敗として計上 |
| `WARN: report gate failed for line <track> — ... receipt ... (ctl-015)` | run スコープの receipt が無い・壊れている — 失敗として計上（timeout で receipt を書く前に落ちた run） |
| `Report existence gate passed: N report(s)` | 当日担当ラインが全て ctl-015 を通過。失敗したラインがある日と、認証・課金のエラーで始めずに残ったラインがある日は、代わりに、ゲートを通ったラインが 1 本以上あれば `=== Failed (E_PARTIAL:<失敗したライン>, exit code 1) ===`、1 本も無ければ `=== Failed (E_NO_REPORT:<失敗したライン>, exit code 1) ===` が出る（始めなかったラインだけの日はコロンの後が空） |
| `Line states: article=N brief=N quiet=N hold=N (...)` | 当日の内訳（今朝 / 更新なし / 未検証 / 取得失敗の疑い の各段は該当があるときだけ出る） |
| `VERIFY <track>: {...}` | 呼2 の照合結果（supported / partial / unsupported / unverifiable / edits / ran） |
| `VERIFY_DIFF <track>: {...}` | 呼2 が実際に変えた量。script が呼2 の前に書く改稿前の写し `state/<line>/pre-verify/{date}.md` と比べる: 変更範囲の数・字数の増減・消えた文・数字の増減・新しい URL・frontmatter / 機会メモ / ソース節の変更の有無。metrics の `verification` に合算する |
| `WARN: Line <track> clarity pass: …` | verify-diff が verification プロトコルの禁止事項（frontmatter、機会メモ、`(未解決 …)` の付記以外のソース節、原稿に無かった URL）の改稿か、`verify.json` と呼2 の完了報告の件数の食い違いを見つけた |
| `WARN: Line <track> pre-verify copy failed — …` / `WARN: Line <track> verify-diff could not run (non-fatal)` | 改稿前の写しを書けなかったか比べられなかった。呼2 の結果は残り、改稿の差分だけが記録されない |
| `WARN: Line <track> verify.json path could not be cleared (…)` | `state/<line>/runs/{date}.verify.json` にファイルでないもの（dir）が居座っている。呼2 は結果を書けず、そのラインは `unverified` として計上する。run は続く。手で消す |
| `WARN: report lint hard fail (ctl-016): ...` | 決定論 lint がソース節不在・出典 0 件を検出 |
| `WARN: clarity pass failed ...` | 呼2（検証 + clarity）の失敗 (fail-open — run 全体は成功のまま、そのラインは `unverified` として計上) |
| `Audit pass: on (model <m>, effort high, ADR-0020)` | `[audit] enabled = true`。article ごとに呼2 の後で呼3 が走る |
| `AUDIT <track>: {...}` | そのラインの呼3 の集計: `ran`（第 1 段が読める結果を返したか）、`reason`（返さなかった理由: `E_TRANSIENT` などの呼び出しの分類・`parse`・`E_BUDGET_GATE`・`E_STATE`（状態のパスを消せなかった）・`note_unreadable`）、確かめた主張・一致・原典が取れない主張の数、`invalid`（形が壊れていて捨てた候補）、`candidates`、`confirmed`（両段が食い違いとした）、`applied`、`rejected`、第 2 段の呼び出し数・turns・費用。metrics の `verification` に `audit_*` として合算する |
| `WARN: Line <track> audit stage 1 did not run or failed (<class>) — …` | 第 1 段を始めなかった（支出の上限・ノートが読めない・長すぎる）か失敗した。ノートは呼2 の後のままで、run の成否は変わらない |
| `WARN: Line <track> audit pass: 監査で確定した候補 D<n> を適用しなかった (<規則>) — …` | 両段が誤りと確定したが、置き換えが規則に外れた（`not_found` / `ambiguous` / `outside_body`: 文が本文にちょうど 1 回ない、`empty`、`unchanged`、`short`: 文が 15 字未満、`newline`: 文か置き換え文が改行を含む、`control` / `invisible` / `disallowed_char`: 置き換えが足す字・消す字に制御文字・ゼロ幅や bidi の文字・字と数字と空白と基本の句読点（`%` `&` を含む）の外の字がある、`edit_distance`: 書き換えが max(24, 元の文の 30%) 字を超える、`url_changed` / `link_changed` / `heading_changed` / `html_changed` / `entity_changed` / `comment_changed` / `markup`: ノートの URL（`www.` を含む）・link（link 先・`!` の埋め込み・wikilink・参照形の定義）・見出しと `-` だけの行・HTML のタグ・HTML エンティティ・`%%` の数・書式の記号の並びが変わる、`fix_unconfirmed`: 第 2 段が置き換え文を原典と両立するとしなかった、`span_mismatch`: 置き換え文が第 2 段の見つけた誤りの訂正を持たないか、その外も書き換えた）。誤りはノートに残る — `state/<line>/audit/{date}.json` を見て手で直す |
| `WARN: Line <track> audit pass: 監査の置き換えをノートに書けなかった (<エラー>) — ノートは元のまま` | 置き換えた全文をノートに書けなかった。適用した候補は全部 `rejected`（`write_failed`）として記録され、ノートは変わらない |
| `WARN: Line <track> audit stage 2 stopped — …` / `WARN: Line <track> audit pass skipped — …` | api mode でその日の残額が次の監査の呼び出しに足りなくなった（`API spend cap`）か、支出の gate が上限を確かめられなかった（`could not check the caps`、理由は直前の ERROR 行）。または監査を始めなかった（認証・課金のエラーの後、または `the audit state path could not be cleared`: `state/<line>/audit/{date}.json` にファイルでないものが居座っている — 手で消す） |
| `Line <track> audit pass skipped (kind: brief, only article is audited)` | brief は監査しない |
| `Completed successfully` | 当日担当ラインが全て完了・レポートゲート通過（全ライン quiet の日も含む） |

### 通知メッセージ

| 通知 | 意味 |
|---------|------|
| `今朝のリサーチレポートが完成しました (今朝: … / 更新なし: … / 未検証: …)` | 全ライン成功し、公開されたレポートがある |
| `今朝は更新なし (更新なし: …)` | 全ラインが quiet / hold で終わった（成功） |
| `リサーチが一部失敗しました (今朝: … / 更新なし: … / failed: …)。ログを確認してください。` | E_PARTIAL — 失敗したラインを名指しする。認証・課金のエラー（401 / 403 / 429 / クレジット）で run が止まり、当日担当ラインが始まらずに残り、ゲートを通ったラインが 1 本以上ある日は、ゲートに落ちたラインが無くても E_PARTIAL で、そのラインは「未実行」に並ぶ。ゲートを通ったラインが 1 本も無い日は E_NO_REPORT で、その通知 `リサーチが失敗しました (lines:…)` は失敗したラインだけを並べる。最後の担当ラインでのエラーは始めずに残るラインを作らないので、その日の通知はゲートだけで決まる（呼2 が失敗したノートは「未検証」に並ぶ） |

「未検証」は呼2 が失敗した（または verify.json が無い）ラインで、レポート自体は公開されている。「取得失敗の疑い」が付く quiet / hold は、web 検索 0 回または `reason_code = fetch_failed` のラインで、ネットワーク側の問題を疑う材料になる。

## よくある問題と対処法

### 1. OAuth トークン期限切れ（subscription モード）

**症状**: ログに `ERROR: Auth probe failed (subscription) — …` が出力される。macOS 通知が表示される。

**原因**: Claude の OAuth トークンは約4日で期限切れになる。

**対処**:
```bash
# Claude CLI を対話モードで起動してトークンを更新
claude
# 認証プロンプトが表示されたら完了させて終了
# 確認:
./scripts/check-auth.sh
```

**予防策**: 週2回以上 `claude` を対話モードで起動する。

### 2. `claude` コマンドが見つからない

**症状**: ログに `ERROR: claude command not found in PATH` が出力される。

**原因**: launchd 環境の PATH に Claude CLI のインストール先が含まれていない。

**対処**:
```bash
# claude のインストール先を確認
which claude

# そのパスが daily-research.sh の PATH export と
# plist の EnvironmentVariables PATH に含まれているか確認
```

### 3. ロックファイルによる実行ブロック

**症状**: ログに `ERROR: Another instance is running. Skipping.` または `ERROR: Could not verify the lock (…). Skipping.` が出力される。

**原因**: `Another instance` — 前回の実行がまだ実行中、またはクラッシュした run の PID を別の `daily-research.sh` が再利用している。`Could not verify the lock` — 確認そのものが失敗し、二重実行の危険を避けて skip した: mutex `.daily-research.lock.mutex` を 10 秒で取れない（止まった process が持っている — `lsof .daily-research.lock.mutex` で探す）、mutex を取る `python3` が失敗した・PATH に無い、mutex のファイルかロックディレクトリを作れない（権限・ディスク）。

**対処**:
```bash
# ロックは pid ファイルを持つディレクトリ
cat .daily-research.lock/pid
ps aux | grep daily-research

# プロセスが存在しない場合、古いロックディレクトリを削除
# （PID が死んでいる・pid が無いか空のロックと、PID が daily-research.sh 以外の process のもの（再起動後の
#  PID の再利用など）になったロックは、次回起動時にスクリプト自身が奪取する。隣の .daily-research.lock.mutex は
#  取得の排他に使う常設ファイルで、消さない）
rm -rf .daily-research.lock
```

### 4. 特定のラインが失敗し続ける

**症状**: ログに `WARN: Line <track> failed after retry` または `WARN: report gate failed for line <track> — ... (ctl-015)` が連日出力される。

**原因**:
- レート制限（subscription モードではプラン枠の消費。api モードの 429 は run を止める — 問題 5）または WebSearch 中のネットワーク障害
- 深掘りしすぎた run がライン単位の 25 分タイムアウトを超過
- `config.toml` の `target_repo` パスが存在しない・移動した（`mode = "ecosystem"` のラインは `target_repo` を持たない — スクリプトが作る `state/<line>` で走り、`Line <track> mode: ecosystem (cwd = state/<track>)` を出力する）

**対処**: ログで exit 分類（`E_TRANSIENT` / `E_FATAL`）を確認する。1 ラインの失敗は他のラインを止めない — 他のレポートは生成・ingest され、その日の final class は `E_PARTIAL`（exit 1、`=== Failed (E_PARTIAL:<lines>, exit code 1) ===`）になる。`E_NO_REPORT` はゲートを通ったラインが 1 本も無い日に限る（ADR-0011 / ADR-0017 — 全ラインが quiet で終わった日は成功であって `E_NO_REPORT` ではない）。`target_repo` の存在を確認してから手動で再実行する。401（`E_AUTH`）は OAuth 期限切れ（問題 1）か、api モードでの key の拒否（問題 5）。

### 5. api モード: key の拒否・クレジット・レート制限・支出上限

**症状**: ログに `ERROR: Auth probe failed (api) — …`、`hit a billing/rate-limit error`、`API spend gate stopped the run`、`API spend gate could not check the caps` のどれかが出て、macOS 通知が表示される。

**原因と対処**:
- `status=401` / `403`: `credential = "env_file"` なら `env_file` の key が違うか期限切れか失効している。そこで差し替える（repo には置かない）。`credential = "ant"` なら Console のログインを更新できなかったので、`ant auth login --profile <ant_profile>` でログインし直す。どちらも `./scripts/check-auth.sh` で確かめる。
- `Your credit balance is too low`: platform.claude.com でクレジットを足す。
- `status=429`: レート制限。backoff で踏み抜かず、意図して止めている（連発する rate limit は policy signal）。時間をおいて手で再実行する。
- `API spend gate stopped the run`: 1 日または 1 か月の残額が 1 ライン分の予約額（`call1_max_usd + call2_max_usd`。`[audit] enabled` なら `audit_max_usd + 5 × audit_confirm_max_usd` を足す。ログの `Billing: api` 行に `line reserve` として出る）を下回った。`state/api-spend.jsonl` を確認し、上限はクレジットが足りるときだけ `[billing]` で上げる。
- `ERROR: API spend gate failed (rc …): …` か `ERROR: API spend ledger could not be written …` の直後の `API spend gate could not check the caps`: 上限を判定できなかったので、gate が次のラインの前で止めた。残りのラインは始まらず（最初のラインの前なら全部）、完走済みのラインの成果は残る。rc 2 のメッセージは台帳の読めない行のうち先頭 5 件を行番号と理由で名指し、残りを `and N more` で数える。`state/api-spend.jsonl` のその行を直すか消して（または書き込めるように戻して）から再実行する。

課金経路は設定なしに変わらない。subscription モードではシェルで export した `ANTHROPIC_API_KEY` を捨て、api モードでは `[billing] credential` が指す資格情報だけを使う（親の環境の `ANTHROPIC_AUTH_TOKEN`・`CLAUDE_CONFIG_DIR` も捨てる）。

### 6. レポートが Obsidian に表示されない

**症状**: スクリプトは正常終了するがレポートが Obsidian に表示されない。

**原因**: iCloud 同期の遅延、または vault パスの変更。

**対処**:
```bash
# vault パスが config.toml と一致しているか確認
grep vault_path config.toml

# ディスク上にファイルが存在するか確認（vault_path を使用）
ls "/path/to/your/obsidian/vault/daily-research/"

# iCloud 同期を促す: iOS のファイルアプリを開くか、しばらく待つ
```

### 7. プラグインによる実行遅延・ハング

**症状**: `claude -p` の run が起動だけでタイムアウトの多くを消費する、または無限にハングする。

**原因**: Claude Code のプラグイン（pyright, swift-lsp, hookify, mgrep, claude-mem 等）がグローバルにインストールされている。`--safe-mode` の無い `claude -p` 呼び出しは全プラグインの MCP サーバーを初期化し、大幅なオーバーヘッドが発生する。無人の呼び出し（呼1・呼2・認証 probe）は `--safe-mode` で起動し、インストール済みのプラグインと MCP サーバーを外すので、これが当たるのはこのプロジェクトで手で起動する `claude`（対話でプロトコルを追う場合など）。それでも起動で止まるライン run は別の原因を疑う。無人の呼び出しはすべて `timeout -k` で上限が付く。

**対処**: プロジェクトルートに `.claude/settings.json` を作成し、プラグインを無効化する:
```json
{
  "enabledPlugins": {
    "plugin-name@marketplace": false
  }
}
```

`claude plugin list` でインストール済みプラグインを確認し、それぞれ `false` に設定する。この設定はこのプロジェクトにのみ影響し、他のプロジェクトやインタラクティブセッションには影響しない。

**確認方法**:
```bash
# プラグイン無効化後、MCP サーバーが起動していないことを確認:
ps aux | grep -E "pyright|sourcekit|claude-mem|sequential|japanese|ableton"
```

**備考**: 現時点では「全プラグイン一括無効化」の設定は存在しない。各プラグインを個別に列挙する必要がある。[追跡 Issue](https://github.com/anthropics/claude-code/issues/20873) 参照。

### 8. 問いの重複

**症状**: 最近と同じ問いに同じ答えを返すレポートが生成される（同じ topic を別の問いで扱うのは正常）。

**原因**: `past_topics.json` が正しく更新されていない（run の問い選定はここから渡される過去の問い・`answer_scope` の一覧に依存する）。script はゲートを通ったラインの問いを receipt から追記する（`past-topics-append`）。失敗するとログに `WARN: Line <track> past_topics.json append failed` が出る。`state/<line>/brief.md` はあなたが書く静的な文書なので、同じ題材に戻り続けるならそこで主題を絞るか言い換える。

**対処**:
```bash
# past_topics.json を確認
cat past_topics.json | python3 -m json.tool

# 破損している場合はバックアップから復元
cp past_topics.json.bak past_topics.json
```

### 9. 監査（呼3）がノートを変えた、または誤りを残した

**症状**: ノートが呼2 の後と違って読める、またはログに `audit pass: 監査で確定した候補 … を適用しなかった` / `audit stage 1 did not run or failed`。

**見る場所**: `state/<line>/audit/{date}.json` に候補ごとの状態（`applied`、`rejected` + 規則、`not_confirmed` + 第 2 段の判定、`confirm_failed`、`skipped` + `drift` / `url_not_in_note` / `duplicate` / `over_cap`）と、各段が読んだ原典の引用と URL、第 2 段の置き換え文の判定とそれが見つけた誤り・訂正の部分がある。`state/<line>/pre-audit/{date}.md` は監査の前のノート。

**対処**:
```bash
# 監査が変えたところ
diff state/<line>/pre-audit/<date>.md "<vault_path>/daily-research/<date>_<line>_<slug>.md"

# 1 本のノートの監査を取り消す（監査の前の写し = 呼2 の後のノート）
cp state/<line>/pre-audit/<date>.md "<vault_path>/daily-research/<date>_<line>_<slug>.md"

# 監査を止める: config.toml で
#   [audit]
#   enabled = false
```

## ロールバック手順

### 設定変更の取り消し

```bash
git diff config.toml
git checkout config.toml
```

### past_topics.json の復元

```bash
cp past_topics.json.bak past_topics.json
```

### 自動実行の停止

```bash
launchctl unload ~/Library/LaunchAgents/com.daily-research.plist
```

### 自動実行の再開

```bash
launchctl load ~/Library/LaunchAgents/com.daily-research.plist
```

## スケジュール

| 時刻 | アクション |
|------|-----------|
| AM 5:00 | launchd が `daily-research.sh` を実行（ライン単位リサーチ） |

予定時刻に Mac がスリープ中だった場合、復帰時に launchd がジョブを実行する（`StartCalendarInterval` の仕様）。

## コスト

毎朝、輪番 window で選ばれた `lines_per_day` 本のラインと、`daily = true` の全ラインが走る（ADR-0010 / ADR-0011 / ADR-0017 / ADR-0019）。ラインごとに、呼1 = Opus の研究 run（リトライ込みで最大 2 回）と、呼2 = 検証 + clarity（`[verification] model`）が 1 回ずつ走る。quiet / hold で終わったラインは呼2 を飛ばす。`[audit] enabled` なら、article に呼3 = 監査 1 回と候補ごとの確認（最大 5 回）が足される（`[audit] model`）。timeout とターン数の上限は `scripts/daily-research.sh` にある。

**誰が払うか**は `config.toml` の `[billing] mode` で決まる（`scripts/lib/billing.sh`。契約の正本は `scripts/lib/dr_pipeline.py` の `[billing]`）:

| mode | 認証 | 課金 | 上限 |
|---|---|---|---|
| `subscription`（既定） | Claude Code のログイン（OAuth） | Max プランならトークン単位の課金なし。プランの利用上限に数えられる | プランの上限。環境にある `ANTHROPIC_API_KEY` は捨てる |
| `api` | `credential = "env_file"`: `env_file` から読む `ANTHROPIC_API_KEY`（repo の外のファイルで、モデルの読み取りは拒否される）。`credential = "ant"`: `ant auth login` の Console ログインのアクセストークン（呼び出しごとに取り直す。`~/.config/anthropic` はモデルの読み取りを拒否）を使い、claude は claude.ai ログインを持たない専用の `state/claude-config` で動かす | すべての呼び出しが Claude API の課金 | 呼び出しごとに `--max-budget-usd`（`call1_max_usd`、`call2_max_usd`、`audit_max_usd`、`audit_confirm_max_usd`）。1 日と 1 か月の残額がどちらも 呼1 + 呼2（`[audit] enabled` なら + 監査の予約額）の分を満たすときだけラインを始める（`daily_cap_usd`、`monthly_cap_usd`）。満たさなければ残りのラインを止めて通知する。1 本も始められなかった日は `E_BUDGET`（exit 1） |

`api` モードでは、呼び出しごとの費用（Claude Code が報告する `total_cost_usd`。認証 probe を含む）を `state/api-spend.jsonl` に追記する。上限の判定はこのファイルを読み、その日と月の合計は `API spend: today … month …` としてログに出る。429、クレジット残高の不足、key の拒否が出たら、再試行せずに残りのラインを止める（`E_BILLING` / `E_AUTH`）。

**実際の支出。** その月の支出は `./scripts/check-auth.sh` が表示し、`state/api-spend.jsonl` には呼び出しごとに 1 行ある。上限の既定値は `config.example.toml` にあり、自分の値は台帳を見て決める。
