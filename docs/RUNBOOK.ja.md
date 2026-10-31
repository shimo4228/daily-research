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
├── ロック取得（アトミック mkdir）
├── 課金経路の設定（[billing]: api = env_file の ANTHROPIC_API_KEY、subscription = OAuth）
├── 認証 probe（その経路で Haiku を実際に 1 回呼ぶ）
├── config schema チェック（ADR-0008 以前の旧 schema は fail-fast）
├── rotation-pick — 当日担当ラインを決定論選択: 輪番 window（開始 = date.toordinal() × K
│   mod N、そこから連続 K 本。K = [general] lines_per_day、ADR-0010 / ADR-0017）
│   + `daily = true` の全ライン（毎日実行、ADR-0011）
├── 呼1: claude -p, cwd = 担当ラインの target_repo (Opus, --max-turns 55,
│   25 分タイムアウト, transient 失敗時リトライ 1 回; 401 は中止)
│   [api モード: ラインの前に支出ゲート（日・月の上限）、呼び出しごとに --max-budget-usd、
│    呼び出しごとの費用を state/api-spend.jsonl に追記。429 とクレジット切れは run を止める]
│   [mode = "ecosystem" のラインは target_repo を持たない: cwd = state/<line>、
│    prompts/ecosystem-research-protocol.md、--safe-mode 付き — ADR-0018]
│   ├── 短い文脈（line brief + state/<line>/brief.md + 問いの履歴 + pending.md）を Read
│   ├── watched sources の diff-first 確認 + 広い探索 · 問いの候補 3〜6 件から 1 つ選ぶ
│   │   （または quiet / hold）· 選定後に context_files を Read · citation ゲート付き
│   │   リサーチ · 根拠ファイル runs/{date}.md
│   ├── 解説ノート（固定見出しなし。article ≤ 3,000 字 / brief 300〜600 字）を vault に
│   │   Write（quiet / hold の日は書かない）
│   └── run receipt runs/{date}.json を記事の直後に Write · state + past_topics.json 更新
├── ctl-015 レポート存在ゲート（receipt 駆動: receipt 無し / 不正 → 失敗、article・brief は
│   vault の {date}_{track}_*.md を要求、quiet・hold はファイル無しで成功）
├── 呼2: fresh-context の検証 + clarity (既定 Sonnet, --max-turns 30, 20 分タイムアウト,
│   研究文脈なし, Read + WebFetch, Edit は対象ノートと runs/{date}.verify.json のみ,
│   WebSearch は disallow, 失敗は fail-open — 未検証版が残り run は成功のまま, ADR-0017)
├── ctl-016 決定論的レポート lint（固定節 = 機会メモ / ソース、report-template.md に同期。
│   kind: brief は機会メモと文字数の soft を免除）
├── Pass 3: Obsidian wiki ingest（vault 側スクリプト、non-fatal）
└── metrics.jsonl 追記 (clarity_pass / line_states / verification 含む) + /dr-review 経過日数チェック
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
| `ERROR: billing setup failed — …` | `[billing]` が不正、または（api モードで）`env_file` に `ANTHROPIC_API_KEY` が無い。どの呼び出しより前に停止（exit 1） |
| `Auth probe passed` | 実際に呼び出す認証 probe が成功 |
| `ERROR: Auth probe failed (<mode>) — status=… result=…` | probe が失敗（OAuth 期限切れ、または api モードで key の拒否・クレジット不足・429）。ライン実行前に停止（exit 1） |
| `WARN: API spend gate stopped the run (month $… / $…, day $… / $…, need $… per line) — stopping remaining lines` | api モード: 残額があと 1 ライン分に満たない、または（直前の `ERROR: … spend …` 行のとおり）台帳が書けない・読めない。残りは止め、`Lines not started: …` に名前が出る |
| `ERROR: Line <track> hit a billing/rate-limit error — aborting remaining lines, no retry` | api モード: 429 またはクレジット残高不足（`E_BILLING`） |
| `WARN: Line <track> reached --max-budget-usd $… — no retry, going to gate` | 呼び出しごとの上限で呼1 が止まった。書けた分でゲートへ進む |
| `API spend: today $… / $…, month $… / $…` | api モード: run 後の `state/api-spend.jsonl` の合計 |
| `ERROR: Another instance is running. Skipping.` | ロックディレクトリ `.daily-research.lock/` を生存中の PID が保持している |
| `Config schema check passed` | `config.toml` が現行 (ADR-0008) schema に適合 |
| `Rotation pick: a, b, c (ADR-0010/0017)` | 当日担当ラインの輪番 window 選択結果 |
| `Today's lines: N` | 当日実行するライン数（`lines_per_day` + daily ライン） |
| `=== Line: <track> (<repo パス>) ===` | その repo を cwd にしたライン run の開始（ecosystem ラインは repo を持たず `no target repo` と出る） |
| `Line <track> mode: ecosystem (cwd = state/<track>, safe mode)` | `mode = "ecosystem"` のライン。state ディレクトリを cwd に、ecosystem プロトコルで走る（ADR-0018）。`--safe-mode` は全ラインに付く（ADR-0019） |
| `SUMMARY Run(<track>): cost=... turns=... duration=...` | ライン run の実行統計（コスト、ターン数、所要時間、トークン数） |
| `WARN: Line <track> failed (..., exit N) — retrying once` | transient 失敗。1 回きりのリトライを開始 |
| `ERROR: Line <track> returned 401 — aborting remaining lines (…)` | run 中に認証が失敗（401 / 403: OAuth 期限切れか key の拒否）。残ラインは中断、完走済みラインの成果は保持 |
| `Line <track> state: <status>` | receipt が申告した内容状態（article / brief / quiet / hold） |
| `Line <track> report gate passed` | ctl-015: そのラインが receipt どおりの成果を残した（article / brief は `{date}_{track}_*.md` が vault に存在、quiet / hold はファイル無しで通過） |
| `WARN: report gate failed for line <track> — no <date>_<track>_*.md (ctl-015)` | receipt が article / brief なのにレポートが無い — 失敗として計上 |
| `WARN: report gate failed for line <track> — ... receipt ... (ctl-015)` | run スコープの receipt が無い・壊れている — 失敗として計上（timeout で receipt を書く前に落ちた run） |
| `Report existence gate passed: N report(s)` | 当日担当ラインが全て ctl-015 を通過（一部失敗時は `Failed (E_PARTIAL: ...)` になる） |
| `Line states: article=N brief=N quiet=N hold=N (...)` | 当日の内訳（今朝 / 更新なし / 未検証 / 取得失敗の疑い の各段は該当があるときだけ出る） |
| `VERIFY <track>: {...}` | 呼2 の照合結果（supported / partial / unsupported / unverifiable / edits / ran） |
| `WARN: report lint hard fail (ctl-016): ...` | 決定論 lint がソース節不在・出典 0 件を検出 |
| `WARN: clarity pass failed ...` | 呼2（検証 + clarity）の失敗 (fail-open — run 全体は成功のまま、そのラインは `unverified` として計上) |
| `Completed successfully` | 当日担当ラインが全て完了・レポートゲート通過（全ライン quiet の日も含む） |

### 通知メッセージ

| 通知 | 意味 |
|---------|------|
| `今朝のリサーチレポートが完成しました (今朝: … / 更新なし: … / 未検証: …)` | 全ライン成功し、公開されたレポートがある |
| `今朝は更新なし (更新なし: …)` | 全ラインが quiet / hold で終わった（成功） |
| `リサーチが一部失敗しました (今朝: … / 更新なし: … / failed: …)。ログを確認してください。` | E_PARTIAL — 失敗したラインを名指しする |

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

**症状**: ログに `ERROR: Another instance is running. Skipping.` が出力される。

**原因**: 前回の実行がまだ実行中、またはクラッシュしてクリーンアップされなかった。

**対処**:
```bash
# ロックは pid ファイルを持つディレクトリ
cat .daily-research.lock/pid
ps aux | grep daily-research

# プロセスが存在しない場合、古いロックディレクトリを削除
# （PID が死んでいるロックは次回起動時にスクリプト自身が奪取する）
rm -rf .daily-research.lock
```

### 4. 特定のラインが失敗し続ける

**症状**: ログに `WARN: Line <track> failed after retry` または `WARN: report gate failed for line <track> — ... (ctl-015)` が連日出力される。

**原因**:
- レート制限（subscription モードではプラン枠の消費。api モードの 429 は run を止める — 問題 5）または WebSearch 中のネットワーク障害
- 深掘りしすぎた run がライン単位の 25 分タイムアウトを超過
- `config.toml` の `target_repo` パスが存在しない・移動した（`mode = "ecosystem"` のラインは `target_repo` を持たない — スクリプトが作る `state/<line>` で走り、`Line <track> mode: ecosystem (cwd = state/<track>, safe mode)` を出力する）

**対処**: ログで exit 分類（`E_TRANSIENT` / `E_FATAL`）を確認する。1 ラインの失敗は他のラインを止めない — 他のレポートは生成・ingest され、その日の final class は `E_PARTIAL`（exit 1、`=== Failed (E_PARTIAL:<lines>, exit code 1) ===`）になる。`E_NO_REPORT` はゲートを通ったラインが 1 本も無い日に限る（ADR-0011 / ADR-0017 — 全ラインが quiet で終わった日は成功であって `E_NO_REPORT` ではない）。`target_repo` の存在を確認してから手動で再実行する。401（`E_AUTH`）は OAuth 期限切れ（問題 1）か、api モードでの key の拒否（問題 5）。

### 5. api モード: key の拒否・クレジット・レート制限・支出上限

**症状**: ログに `ERROR: Auth probe failed (api) — …`、`hit a billing/rate-limit error`、`API spend gate stopped the run` のどれかが出て、macOS 通知が表示される。

**原因と対処**:
- `status=401` / `403`: `env_file` の key が違うか失効している。そこで差し替え（repo には置かない）、`./scripts/check-auth.sh` で確かめる。
- `Your credit balance is too low`: platform.claude.com でクレジットを足す。
- `status=429`: レート制限。backoff で踏み抜かず、意図して止めている（連発する rate limit は policy signal）。時間をおいて手で再実行する。
- `API spend gate stopped the run`: 1 日または 1 か月の残額が 1 ライン分の予約額（`call1_max_usd + call2_max_usd`）を下回った。`state/api-spend.jsonl` を確認し、上限はクレジットが足りるときだけ `[billing]` で上げる。

課金経路は設定なしに変わらない。subscription モードではシェルで export した `ANTHROPIC_API_KEY` を捨て、api モードでは `env_file` の key だけを使う。

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

**症状**: ライン run が起動だけで 25 分タイムアウトの大半を消費する、または無限にハングする。

**原因**: Claude Code のプラグイン（pyright, swift-lsp, hookify, mgrep, claude-mem 等）がグローバルにインストールされている。`claude -p` 呼び出しごとに全プラグインの MCP サーバーが初期化され、大幅なオーバーヘッドが発生する。

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

**原因**: `past_topics.json` が正しく更新されていない（run の問い選定はここから渡される過去の問い・`answer_scope` の一覧に依存する）。`state/<line>/brief.md` はあなたが書く静的な文書なので、同じ題材に戻り続けるならそこで主題を絞るか言い換える。

**対処**:
```bash
# past_topics.json を確認
cat past_topics.json | python3 -m json.tool

# 破損している場合はバックアップから復元
cp past_topics.json.bak past_topics.json
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

毎朝、輪番 window で選ばれた `lines_per_day` 本のラインと、`daily = true` の全ラインが走る（ADR-0010 / ADR-0011 / ADR-0017 / ADR-0019）。ラインごとに、呼1 = Opus の研究 run（リトライ込みで最大 2 回）と、呼2 = 検証 + clarity（`[verification] model`）が 1 回ずつ走る。quiet / hold で終わったラインは呼2 を飛ばす。timeout とターン数の上限は `scripts/daily-research.sh` にある。

**誰が払うか**は `config.toml` の `[billing] mode` で決まる（`scripts/lib/billing.sh`。契約の正本は `scripts/lib/dr_pipeline.py` の `[billing]`）:

| mode | 認証 | 課金 | 上限 |
|---|---|---|---|
| `subscription`（既定） | Claude Code のログイン（OAuth） | Max プランならトークン単位の課金なし。プランの利用上限に数えられる | プランの上限。環境にある `ANTHROPIC_API_KEY` は捨てる |
| `api` | `env_file` から読む `ANTHROPIC_API_KEY`（repo の外のファイルで、モデルの読み取りは拒否される） | すべての呼び出しが Claude API の課金 | 呼び出しごとに `--max-budget-usd`（`call1_max_usd`、`call2_max_usd`）。1 日と 1 か月の残額がどちらも 呼1 + 呼2 の分を満たすときだけラインを始める（`daily_cap_usd`、`monthly_cap_usd`）。満たさなければ残りのラインを止めて通知する。1 本も始められなかった日は `E_BUDGET`（exit 1） |

`api` モードでは、呼び出しごとの費用（Claude Code が報告する `total_cost_usd`。認証 probe を含む）を `state/api-spend.jsonl` に追記する。上限の判定はこのファイルを読み、その日と月の合計は `API spend: today … month …` としてログに出る。429、クレジット残高の不足、key の拒否が出たら、再試行せずに残りのラインを止める（`E_BILLING` / `E_AUTH`）。

**実際の支出。** その月の支出は `./scripts/check-auth.sh` が表示し、`state/api-spend.jsonl` には呼び出しごとに 1 行ある。上限の既定値は `config.example.toml` にあり、自分の値は台帳を見て決める。
