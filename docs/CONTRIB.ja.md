# 開発ガイド

> 正式な情報源: `config.example.toml`, `scripts/*.sh`, `scripts/lib/dr_pipeline.py`, `prompts/*.md`, `com.example.daily-research.plist`

## 前提条件

| ツール | 用途 | インストール |
|--------|------|-------------|
| Claude Code CLI | コア実行エンジン | `brew install claude` or [docs.anthropic.com](https://docs.anthropic.com) |
| Claude Max プラン または Claude API の key | `claude -p` の呼び出しの支払い。`config.toml` の `[billing] mode` で選ぶ | サブスクリプション契約、または platform.claude.com の key を repo 外の env ファイルに置く |
| macOS (launchd) | スケジューラ | OS組み込み |
| python3 >= 3.11 | JSON/TOML 解析（`scripts/lib/dr_pipeline.py`）; stdlib のみ | Homebrew `python3`（macOS system 3.9 は `tomllib` 非対応） |
| bats-core | シェルテストフレームワーク | `brew install bats-core` |
| shellcheck | シェルスクリプト静的解析 | `brew install shellcheck` |

## プロジェクト構成

```
daily-research/
├── config.example.toml                  # line → repo マッピング、lines_per_day、context_files、daily フラグ（テンプレート）
├── past_topics.json                     # 問い・テーマ履歴（重複防止用、gitignored）
├── prompts/
│   ├── repo-research-protocol.md       # per-repo リサーチプロトコル、呼1、mode = "repo"（--append-system-prompt-file 用）
│   ├── ecosystem-research-protocol.md  # エコシステム観測プロトコル、呼1、mode = "ecosystem"（ADR-0018）
│   └── verification-protocol.md        # fresh-context の検証 + clarity プロトコル、呼2（ADR-0017）
├── templates/
│   ├── report-template.md              # 解説レポートの記述規律 + 固定 2 節（frontmatter付き）
│   ├── report-template-edge.md         # edge ライン専用の節構成（ADR-0015）
│   └── report-template-ecosystem.md    # ecosystem ライン専用の節構成（ADR-0018）
├── scripts/
│   ├── daily-research.sh               # メインエントリポイント（輪番 window で当日 lines_per_day 本: 呼1 研究 + 呼2 検証 + clarity）; lib/ を source
│   ├── check-auth.sh                   # [billing] の経路で認証チェック（real_auth_probe()）+ macOS 通知
│   ├── pre-commit.sh                   # secret / 構文ガード（git pre-commit hook）
│   └── lib/                             # sourced shell ライブラリ + Python 解析モジュール
│       ├── env.sh / log.sh / notify.sh / lock.sh / auth.sh / claude.sh / billing.sh
│       └── dr_pipeline.py              # JSON/TOML 解析の単一 stdlib モジュール
├── state/                               # ラインごとの brief.md / pending.md / watched-sources.md /
│                                        #   playbook.md / runs/{date}.md（根拠ファイル）/ runs/{date}.json
│                                        #   （run receipt）/ runs/{date}.verify.json（gitignored）
├── graph.jsonld                         # 凍結アーカイブ（退役した concept-graph パイプライン）
├── com.example.daily-research.plist    # launchd スケジュール（AM 5:00、リサーチ）
├── tests/
│   ├── test-billing.bats               # API 課金: エラー分類、key の受け渡し、呼び出しごと・日・月の上限
│   ├── test-daily-research.bats        # ユニットテスト（構文、設定、セキュリティ）
│   ├── test-e2e-mock.bats             # E2E モックテスト（ライン単位フロー）
│   ├── test-lib.bats                  # lib/*.sh ユニットテスト（env, lock, auth, claude）
│   ├── test_helper.bash               # bats 共通 helper（refute_grep — grep の否定 assertion は `! grep` でなくこれで書く）
│   └── dr_pipeline_test.py            # dr_pipeline.py の pytest（dev 専用、.venv）
├── logs/                                # 実行ログ（日付別、30日自動ローテーション）
├── docs/
│   ├── RUNBOOK.md / RUNBOOK.ja.md      # 運用ガイド
│   ├── CONTRIB.md / CONTRIB.ja.md      # 開発ガイド（本ファイル）
│   ├── graph-schema.md                 # 凍結 graph.jsonld アーカイブのスキーマ（過去データ用）
│   └── adr/                             # アーキテクチャ決定記録 (ADR)
└── .claude/settings.local.json          # Claude Code プロジェクト権限設定
```

## スクリプト一覧

| スクリプト | 説明 | 使い方 |
|-----------|------|--------|
| `scripts/daily-research.sh` | メインエントリポイント。決定論輪番 window (`rotation-pick`、ADR-0010 / ADR-0017) の `lines_per_day` 本 + `daily = true` の全ライン (ADR-0011) を当日担当に選び、ラインごとに呼1 = `claude -p` を cwd = そのラインの `target_repo` で実行（Opus、25 分タイムアウト、transient 失敗時リトライ 1 回。401 は中止）。`[tracks.<name>].mode = "ecosystem"` のラインは cwd = `state/<line>`、ecosystem プロトコル、`--safe-mode` 付きで実行する（ADR-0018。分岐はライン名ではなく `mode` が決める）。続けて呼2 = fresh-context の検証 + clarity（既定 sonnet、20 分、fail-open）を実行する。`lib/` を source し、環境サニタイズ、認証 probe、config schema チェック、receipt 駆動のレポートゲート (ctl-015)、レポート lint (ctl-016)、metrics 追記（`clarity_pass` / `line_states` / `verification` 含む）を含む。launchd が AM 5:00 に呼び出す。 | `./scripts/daily-research.sh` |
| `scripts/check-auth.sh` | `real_auth_probe()`（共有 `lib/auth.sh`; `claude --version` ではなく実 Haiku API probe。`--version` は期限切れトークンでも成功するため）で、`[billing] mode` が選んだ経路（OAuth、または `env_file` の API key）の認証を確認する。api モードでは今月の支出も表示。失敗時に macOS 通知を表示。 | `./scripts/check-auth.sh` |
| `scripts/pre-commit.sh` | git pre-commit hook として走る secret / 構文ガード。 | （git が自動実行） |

## 環境変数

| 変数 | 設定元 | 用途 |
|------|--------|------|
| `PATH` | plist + スクリプト | `$HOME/.local/bin`（現行 Claude installer）、`$HOME/.claude/local`（旧配置）、`/opt/homebrew/bin`、`/usr/local/bin` を含む必要がある |
| `HOME` | plist | Claude CLI が認証トークンを見つけるために必要 |
| `ANTHROPIC_API_KEY` | `[billing].env_file` だけ | `lib/env.sh` が親の環境の値を捨てる。`api` モードでは `lib/billing.sh` が `env_file` から読んで export し、`subscription` モードでは unset のまま（OAuth） |
| `CLAUDE_TIMEOUT` | スクリプト（内部） | `run_claude()` 経由の `claude -p` 呼び出しのタイムアウト（秒）。0 = 無制限（デフォルト）。呼1 (研究 run) は 1500秒 (25 分)、呼2 (検証 + clarity) は 1200秒 (20 分) を設定 |
| `DEBUG` | ユーザー設定 | `1` に設定するとデバッグログ（PATH、CLAUDE_CMD）を出力 |
| `DR_DATE` | ユーザー設定（テスト seam） | `YYYY-MM-DD` — rotation-pick とレポート名に使う日付を固定する（e2e テストが輪番を固定するために使う）。既定は当日 |
| `DR_ONLY_TRACK` | ユーザー設定（テスト seam） | 当日担当ラインのうち指定ラインだけを実行する。当日担当でないラインを指定するとエラー |
| `DR_FORCE_TRACK` | ユーザー設定（テスト seam） | 当日の輪番 window に関係なく指定 1 ラインを今日の日付で実行する（プロンプト変更の試験用）。launchd 経路では使わない |

## 設定ファイル (`config.toml`)

| セクション | 用途 |
|-----------|------|
| `[general]` | Obsidian vault パス（`vault_path`）、出力ディレクトリ（`output_dir`）、`lines_per_day`（1 日に走らせる本数 = 輪番 window の幅。int ≥ 1、既定 1、違反は fail-fast）、`self_signals`（自己汚染ガード: 運用者自身の成果物を外部シグナルとして数えない）。`language` / `date_format` は参考情報 — スクリプトは読まない |
| `[report]` | 最低出典数 |
| `[verification]` | `model` — 呼2（検証 + clarity）のモデル。既定 `sonnet` |
| `[tracks.<name>]` | ライン 1 つにつき 1 ブロック: `name`, `focus`（そのラインが扱う主題の説明。選択条件ではない）, `aliases`, `context_files`（問いを選んだ後 = Step 3b に Read する repo 相対パス — タスク台帳・open questions・実施履歴）, `sources`, `template`（任意。節構成の上書き、ADR-0015）, `daily`（bool。`true` で輪番の外で毎朝実行、ADR-0011）, `mode`（既定 `"repo"` で省略可、または `"ecosystem"`。未知の値は schema チェックで fail-fast、ADR-0018）+ repo ラインでは `[[tracks.<name>.repos]]` エントリ 1 つ（`key`, `target_repo` — run の cwd になる。`target_doi` は参考情報でスクリプトは読まない）。`mode = "ecosystem"` のラインは `repos` も `context_files` も書けない — repo 文脈を持たないため schema が拒否する |
| `[user_profile]` | 参考情報のみ — スクリプトは読まない |

## 開発ワークフロー

### リサーチ内容を変更する場合

1. **ラインの focus / 1 日の本数** -- `config.toml` の `focus`（主題の説明）/ `[general] lines_per_day` を編集（問いの選定はプロトコル Step 3、ADR-0017 — スコアリング重みは存在しない）
2. **情報源** -- `config.toml` の line sources を編集
3. **問いを選んだ後に読む repo 文脈** -- `config.toml` の `context_files` を編集
4. **レポートフォーマット** -- `templates/report-template.md` を編集（ctl-016 lint の必須節と同期を保つ。`templates/report-template-edge.md` や `templates/report-template-ecosystem.md` などライン別テンプレートにも固定 2 節が同じ形で必要）
5. **リサーチのプロセス・目的関数** -- `prompts/repo-research-protocol.md` を編集、ecosystem ラインは `prompts/ecosystem-research-protocol.md`。2 つの呼1 プロトコルは receipt の形式・根拠ファイルの表・4 つの内容状態・末尾固定 2 節を同じ契約として共有するので、片方を変えたらもう片方も直す（`tests/test-daily-research.bats` が両ファイルに同じ検査を当てる）
6. **検証・clarity の規則** -- `prompts/verification-protocol.md` を編集、モデルは `[verification] model`

### 実行処理を変更する場合

1. `scripts/daily-research.sh` を編集
2. 構文チェック: `bash -n scripts/daily-research.sh`
3. 静的解析: `shellcheck scripts/daily-research.sh`
4. テスト実行: `bats tests/`
5. 手動テスト（launchd 環境を模倣）:
   ```bash
   env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
     /bin/bash scripts/daily-research.sh
   ```

### プロンプトを対話的にテストする場合

```bash
cd ~/MyAI_Lab/daily-research
claude
# prompts/repo-research-protocol.md の手順に沿って手動で確認
```

**補足**: `./scripts/daily-research.sh` は Claude Code セッション内からも実行できます — `lib/env.sh` が `CLAUDECODE` を unset するためネストセッションチェックを通ります（2026-08-22 実証）。1 ラインだけ走らせるには上記の `DR_FORCE_TRACK` / `DR_ONLY_TRACK` / `DR_DATE` seam を使います。

## テスト

```bash
# 全テスト実行
bats tests/

# テストカバー範囲:
# - スクリプト構文の妥当性 (bash -n): daily-research.sh と lib/*.sh
# - 設定ファイルの存在確認
# - launchd plist の妥当性とスケジュール
# - ロック機構
# - ログディレクトリのパーミッション
# - past_topics.json の妥当性
# - セキュリティ（ハードコードされたキーなし、API キー未設定、ログ権限）
# - 防御的プログラミング（set -euo pipefail, trap, max-turns）
# - E2E モック: ライン単位フロー（cwd = repo、プロンプト注入）、ecosystem ラインの実行形
#   （cwd = state/<line>、ecosystem プロトコル、--safe-mode）、リトライ、receipt 駆動のレポートゲート
#   （article / brief / quiet / hold / receipt 欠損 / 不一致）、呼2 の検証結果の取り込み
# - lib/*.sh ユニット: env サニタイズ、アトミックロック、実 auth probe、exit 分類
```

## Claude Code CLI フラグ

### 呼1 — リサーチ run (Opus、担当ラインごと: 輪番 window の `lines_per_day` 本 + daily 全ライン)

run は `cd "$TARGET_REPO"` で起動されるため、repo 自身の CLAUDE.md が context として自動ロードされる。`mode = "ecosystem"` のラインは接地 repo を持たず、代わりに `cd "state/<line>"` で起動される（ADR-0018）。

| フラグ | 値 | 用途 |
|--------|---|------|
| `-p` | ライン単位プロンプト（`dr_pipeline.py line-brief` の line brief + 許可された書き込み先パス（vault のレポート / `state/<line>/` の brief・pending・watched-sources・playbook・根拠ファイル・run receipt / `past_topics.json`）+ 過去の問いの dedup データ + レポートテンプレート） | 非対話モード |
| `--permission-mode` | `default` | デフォルトの権限処理を使用 |
| `--append-system-prompt-file` | `prompts/repo-research-protocol.md`、`mode = "ecosystem"` では `prompts/ecosystem-research-protocol.md` | デフォルト能力を保持しつつリサーチプロトコルを注入 |
| `--safe-mode` | ecosystem ラインのみ | 接地 repo が無いため、運用者の `~/.claude` の CLAUDE.md / rules / skills / plugins / hooks / MCP を run に持ち込まない（safe mode でも `-p` と `--append-system-prompt-file` は有効。2026-09-21 確認）。safe mode は permissions を外さない — 境界は `--disallowedTools` |
| `--disallowedTools`（ecosystem ライン） | `Bash,Task,NotebookEdit` + `Edit(state/<line>/.claude/**)`、`Edit(state/<line>/CLAUDE.md)`、`Edit(state/<line>/.mcp.json)`、`Read(~/.claude/**)`、`Read(~/.codex/**)`（絶対パスで渡す） | cwd が model から書ける場所で、cwd 直下の `.claude/settings.json` は次の run で project settings として読まれる。運用者の harness は permission 層でも読ませない（ADR-0018） |
| `--allowedTools` | `WebSearch,WebFetch,Read,Glob,Grep` + 絶対パス制限付き `Write`/`Edit`（vault レポート dir、`state/<line>/`、`past_topics.json`） | permission 層でも repo を read-only に保つ。書き込みは宣言済み 3 箇所のみ |
| `--max-turns` | `55` | リサーチ深度の目安 |
| `--model` | `opus` | rotation で浮いた日次予算を 1 本の品質に集中させる (ADR-0010) |
| `--output-format` | `json` | メタデータ付き構造化出力（metrics に投入） |
| `--no-session-persistence` | - | 毎回クリーンなコンテキストで実行 |

### 呼2 — 検証 + clarity (既定 Sonnet、article / brief で終わったラインごと)

| フラグ | 値 | 用途 |
|--------|---|------|
| `-p` | 原稿パス + 根拠ファイルのパス + `runs/{date}.verify.json` のパス（書き込みはこの 2 ファイルだけ） | 非対話モード |
| `--append-system-prompt-file` | `prompts/verification-protocol.md` | clarity（Step A）と原典照合（Step B）の手順を注入 |
| `--allowedTools` | `Read,WebFetch` + 当日ノートと `runs/{date}.verify.json` の `Edit` | 原稿と検証結果だけを書き換え可能にする |
| `--disallowedTools` | `Bash,Task,NotebookEdit` + `WebSearch` | 照合は根拠ファイル・ソース節の URL の再取得だけで行う（新しい探索をさせない） |
| `--max-turns` | `30` | 全 claim の WebFetch 照合に必要な深さ |
| `--model` | `[verification] model`（既定 `sonnet`） | 見逃しが目立つなら opus へ上げる |

呼2 は起動前に当日の `verify.json` を削除し、run スコープ（`$LOCK_DIR/pid` より新しい）で読み直す。

**備考**: 全 `claude -p` 呼び出しは `run_claude()` ラッパー経由で `< /dev/null` stdin リダイレクトを使用する。これにより MCP の stdio 通信がターミナルの stdin と競合するのを防止する（過去 MCP ハングの根本原因だった）。

## アーキテクチャ補足

per-repo 単一パス設計は、2026-08-04 に旧中央 2 パス（Opus テーマ選定 → Sonnet リサーチ）パイプラインを置き換えた。同期 concept graph 越しのテーマ選定は裏付けサーベイに収束し、「進めるべき価値」を知る運用文脈は各 repo の中にあるため（ADR-0008）。

リサーチ run は二重に制限される: `--max-turns 55` と 25 分の外部タイムアウト（`run_claude()` 経由の `CLAUDE_TIMEOUT=1500`。coreutils `timeout` が必要）。transient 失敗は 1 回だけリトライされ、401 は同じ認証がどこでも失敗するため即時中止となる。

レポート存在ゲート（ctl-015）は run receipt `state/<line>/runs/{date}.json` を読む: receipt 無し・不正は失敗、`article` / `brief` は run スコープのレポートを要求、`quiet` / `hold` はファイル無しで成功する。run スコープの判定は bash 3.2 の `-nt` が秒精度で信用できないため `find -newer "$LOCK_DIR/pid"` で行う。receipt が quiet/hold なのに記事がある場合は記事を優先し（file wins）`mismatch` を、`reason_code = fetch_failed` か web 検索 0 回の quiet/hold は `suspect` を計上する。

呼2（検証 + clarity、ADR-0017）はゲートの後に走る: fresh-context のプロセス（`--max-turns 30`、`CLAUDE_TIMEOUT=1200`、`--allowedTools` = Read + WebFetch + 当日ノートと `runs/{date}.verify.json` のみの Edit、`--disallowedTools` に WebSearch を追加）が、初見読者としてつまずき箇所を直したうえで根拠ファイルの全 claim を原典と突き合わせる。失敗は fail-open — ログに `WARN: clarity pass failed` を記録し、未検証（timeout 時は部分改稿）の版が残り、`FINAL_EXIT` には影響しない。ただしそのラインは `unverified` として metrics と通知に出る。

`metrics.jsonl` は `expect-check` / `/dr-review` との互換のため ADR-0008 以前のレコード形を維持する: リサーチ run の JSON は `pass2` フィールドに合算され、`pass1` は常に `None`、`fallback_used` は「リトライが発生した」の意味（`pass2` は全 attempt の合算）、`source` は `live` / `test`（`DR_FORCE_TRACK` / `DR_ONLY_TRACK` の run は `test` で記録され `expect-check` / `/dr-review` の集計から除かれる）、`clarity_pass` は呼2 の `{ran, ok, cost, turns, ...}` を記録する（ラベルは互換のため据え置きで、中身は検証 + clarity パスの実測）。これに加えて `line_states {article, brief, quiet, hold, mismatch, suspect, unverified}`（零でも常に出す）と `verification {supported, partial, unsupported, unverifiable, edits, lines_verified}`（VERIFY 行が無い日は `None`）を持つ。判定そのものは保存しない — eval は in-loop 型（ADR-0010）で、残るのは照合結果の内訳だけ。

## 永続メモリ層

2026-02-26 に Mem0 Cloud MCP を統合したが、`.mcp.json` 不在 + ヘルスチェック形骸化により 32 日間ゼロ稼働。2026-05-23 に撤去。後継のローカル JSON-LD concept cluster graph (`graph.jsonld`) も 2026-08-04 に凍結された（ADR-0008）— 増分は停止し、読み出し可能なアーカイブとして残る。永続的な作業状態は現在 `state/<line>/`（brief、pending、watched-sources、playbook、runs の根拠ファイル / receipt / 検証結果）と `past_topics.json` にあり、いずれも失敗が顕在化するローカルファイルである。
