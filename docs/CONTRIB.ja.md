# 開発ガイド

> 正式な情報源: `config.example.toml`, `scripts/*.sh`, `com.example.daily-research.plist`

## 前提条件

| ツール | 用途 | インストール |
|--------|------|-------------|
| Claude Code CLI | コア実行エンジン | `brew install claude` or [docs.anthropic.com](https://docs.anthropic.com) |
| Claude Max プラン | API追加課金なしで利用 | サブスクリプション契約が必要 |
| macOS (launchd) | スケジューラ | OS組み込み |
| python3 >= 3.11 | JSON/TOML 解析（`scripts/lib/dr_pipeline.py`）; stdlib のみ | Homebrew `python3`（macOS system 3.9 は `tomllib` 非対応） |
| bats-core | シェルテストフレームワーク | `brew install bats-core` |
| shellcheck | シェルスクリプト静的解析 | `brew install shellcheck` |

## プロジェクト構成

```
daily-research/
├── config.example.toml                  # line → repo マッピング、context_files、スコアリング（テンプレート）
├── past_topics.json                     # テーマ履歴（重複防止用、gitignored）
├── prompts/
│   └── repo-research-protocol.md       # per-repo リサーチプロトコル（--append-system-prompt-file 用）
├── templates/
│   └── report-template.md              # 解説レポートの記述規律 + 固定 2 節（frontmatter付き）
├── scripts/
│   ├── daily-research.sh               # メインエントリポイント（rotation で当日 1 ライン: 呼1 研究 + 呼2 clarity）; lib/ を source
│   ├── check-auth.sh                   # OAuth チェック（real_auth_probe()）+ macOS 通知
│   ├── pre-commit.sh                   # secret / 構文ガード（git pre-commit hook）
│   └── lib/                             # sourced shell ライブラリ + Python 解析モジュール
│       ├── env.sh / log.sh / notify.sh / lock.sh / auth.sh / claude.sh
│       └── dr_pipeline.py              # JSON/TOML 解析の単一 stdlib モジュール
├── state/                               # ラインごとの watched-sources / playbook / last-seen（gitignored）
├── graph.jsonld                         # 凍結アーカイブ（退役した concept-graph パイプライン）
├── com.example.daily-research.plist    # launchd スケジュール（AM 5:00、リサーチ）
├── tests/
│   ├── test-daily-research.bats        # ユニットテスト（構文、設定、セキュリティ）
│   ├── test-e2e-mock.bats             # E2E モックテスト（ライン単位フロー）
│   ├── test-lib.bats                  # lib/*.sh ユニットテスト（env, lock, auth, claude）
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
| `scripts/daily-research.sh` | メインエントリポイント。決定論輪番 (`rotation-pick`、ADR-0010) の 1 ライン + `daily = true` の全ライン (ADR-0011) を当日担当に選び、ラインごとに呼1 = `claude -p` を cwd = そのラインの `target_repo` で実行（Opus、25 分タイムアウト、transient 失敗時リトライ 1 回。401 は中止）、続けて呼2 = fresh-context clarity 改稿（Sonnet、15 分、fail-open）を実行する。`lib/` を source し、環境サニタイズ、認証 probe、config schema チェック、レポートゲート (ctl-015)、レポート lint (ctl-016)、metrics 追記（`clarity_pass` 含む）を含む。launchd が AM 5:00 に呼び出す。 | `./scripts/daily-research.sh` |
| `scripts/check-auth.sh` | `real_auth_probe()`（共有 `lib/auth.sh`; `claude --version` ではなく実 Haiku API probe。`--version` は期限切れトークンでも成功するため）で OAuth トークンの有効性を確認。失敗時に macOS 通知を表示。 | `./scripts/check-auth.sh` |
| `scripts/pre-commit.sh` | git pre-commit hook として走る secret / 構文ガード。 | （git が自動実行） |

## 環境変数

| 変数 | 設定元 | 用途 |
|------|--------|------|
| `PATH` | plist + スクリプト | `$HOME/.local/bin`（現行 Claude installer）、`$HOME/.claude/local`（旧配置）、`/opt/homebrew/bin`、`/usr/local/bin` を含む必要がある |
| `HOME` | plist | Claude CLI が認証トークンを見つけるために必要 |
| `ANTHROPIC_API_KEY` | **未設定であること** | 設定されていると Max プランではなく従量課金になる |
| `CLAUDE_TIMEOUT` | スクリプト（内部） | `run_claude()` 経由の `claude -p` 呼び出しのタイムアウト（秒）。0 = 無制限（デフォルト）。呼1 (研究 run) は 1500秒 (25 分)、呼2 (clarity) は 900秒 (15 分) を設定 |
| `DEBUG` | ユーザー設定 | `1` に設定するとデバッグログ（PATH、CLAUDE_CMD）を出力 |

## 設定ファイル (`config.toml`)

| セクション | 用途 |
|-----------|------|
| `[general]` | Obsidian vault パス、出力ディレクトリ、言語、日付フォーマット、`self_signals`（自己汚染ガード: 運用者自身の成果物を外部シグナルとして数えない） |
| `[report]` | 最低出典数 |
| `[tracks.<name>]` | ライン 1 つにつき 1 ブロック: `focus`, `aliases`, `context_files`（各 run の冒頭で Read する repo 相対パス — タスク台帳・open questions・実施履歴）, `sources`, `scoring_criteria` + `[[tracks.<name>.repos]]` エントリ 1 つ（`key`, `target_repo` — run の cwd になる, `target_doi` は任意） |
| `[user_profile]` | 任意のスキル / 関心領域 / 目標ヒント |

## 開発ワークフロー

### リサーチ内容を変更する場合

1. **スコアリング重み** -- `config.toml` の scoring_criteria を編集
2. **情報源** -- `config.toml` の line sources を編集
3. **各 run が読む repo 文脈** -- `config.toml` の `context_files` を編集
4. **レポートフォーマット** -- `templates/report-template.md` を編集（ctl-016 lint の必須節と同期を保つ）
5. **リサーチのプロセス・目的関数** -- `prompts/repo-research-protocol.md` を編集

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
# 別のターミナルで実行すること（Claude Code セッション内からは実行不可）
claude
# prompts/repo-research-protocol.md の手順に沿って手動で確認
```

**重要**: `claude -p` は他の Claude Code セッション内から実行できない（ネストセッションチェック）。

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
# - E2E モック: ライン単位フロー（cwd = repo、プロンプト注入）、リトライ、ライン単位レポートゲート
# - lib/*.sh ユニット: env サニタイズ、アトミックロック、実 auth probe、exit 分類
```

## Claude Code CLI フラグ

### 呼1 — リサーチ run (Opus、担当ラインごと: 輪番 1 本 + daily 全ライン)

run は `cd "$TARGET_REPO"` で起動されるため、repo 自身の CLAUDE.md が context として自動ロードされる。

| フラグ | 値 | 用途 |
|--------|---|------|
| `-p` | ライン単位プロンプト（`dr_pipeline.py line-brief` の line brief + 許可された書き込み先パス + 過去テーマ dedup データ + レポートテンプレート） | 非対話モード |
| `--permission-mode` | `default` | デフォルトの権限処理を使用 |
| `--append-system-prompt-file` | `prompts/repo-research-protocol.md` | デフォルト能力を保持しつつリサーチプロトコルを注入 |
| `--allowedTools` | `WebSearch,WebFetch,Read,Glob,Grep` + 絶対パス制限付き `Write`/`Edit`（vault レポート dir、`state/<line>/`、`past_topics.json`） | permission 層でも repo を read-only に保つ。書き込みは宣言済み 3 箇所のみ |
| `--max-turns` | `55` | リサーチ深度の目安 |
| `--model` | `opus` | rotation で浮いた日次予算を 1 本の品質に集中させる (ADR-0010) |
| `--output-format` | `json` | メタデータ付き構造化出力（metrics に投入） |
| `--no-session-persistence` | - | 毎回クリーンなコンテキストで実行 |

**備考**: 全 `claude -p` 呼び出しは `run_claude()` ラッパー経由で `< /dev/null` stdin リダイレクトを使用する。これにより MCP の stdio 通信がターミナルの stdin と競合するのを防止する（過去 MCP ハングの根本原因だった）。

## アーキテクチャ補足

per-repo 単一パス設計は、2026-08-04 に旧中央 2 パス（Opus テーマ選定 → Sonnet リサーチ）パイプラインを置き換えた。同期 concept graph 越しのテーマ選定は裏付けサーベイに収束し、「進めるべき価値」を知る運用文脈は各 repo の中にあるため（ADR-0008）。

リサーチ run は二重に制限される: `--max-turns 55` と 25 分の外部タイムアウト（`run_claude()` 経由の `CLAUDE_TIMEOUT=1500`。coreutils `timeout` が必要）。transient 失敗は 1 回だけリトライされ、401 は同じ認証がどこでも失敗するため即時中止となる。

呼2（clarity 改稿、ADR-0010）はレポート存在ゲートの後に走る: fresh-context の Sonnet プロセス（`--max-turns 15`、`CLAUDE_TIMEOUT=900`、`--allowedTools` = Read + 当日ノートのみの Edit）が完成ノートを初見読者として読み、つまずき箇所を直す。失敗は fail-open — ログに `WARN: clarity pass failed` を記録し、未改稿（timeout 時は部分改稿）の版が残り、`FINAL_EXIT` には影響しない。

`metrics.jsonl` は `expect-check` / `/dr-review` との互換のため ADR-0008 以前のレコード形を維持する: リサーチ run の JSON は `pass2` フィールドに合算され、`pass1` は常に `None`、`fallback_used` は「リトライが発生した」の意味、`clarity_pass` は呼2 の `{ran, ok, cost, turns, ...}` を記録する（verdict 自体は保存しない — eval は in-loop 型、ADR-0010）。

## 永続メモリ層

2026-02-26 に Mem0 Cloud MCP を統合したが、`.mcp.json` 不在 + ヘルスチェック形骸化により 32 日間ゼロ稼働。2026-05-23 に撤去。後継のローカル JSON-LD concept cluster graph (`graph.jsonld`) も 2026-08-04 に凍結された（ADR-0008）— 増分は停止し、読み出し可能なアーカイブとして残る。永続的な作業状態は現在 `state/<line>/`（watched-sources、playbook）と `past_topics.json` にあり、いずれも失敗が顕在化するローカルファイルである。
