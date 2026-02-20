# 開発ガイド

> 正式な情報源: `config.example.toml`, `scripts/*.sh`, `com.example.daily-research.plist`

## 前提条件

| ツール | 用途 | インストール |
|--------|------|-------------|
| Claude Code CLI | コア実行エンジン | `brew install claude` or [docs.anthropic.com](https://docs.anthropic.com) |
| Claude Max プラン | API追加課金なしで利用 | サブスクリプション契約が必要 |
| macOS (launchd) | スケジューラ | OS組み込み |
| python3 | JSON スキーマ検証（Pass 1 出力） | macOS プリインストール |
| bats-core | シェルテストフレームワーク | `brew install bats-core` |
| shellcheck | シェルスクリプト静的解析 | `brew install shellcheck` |

## プロジェクト構成

```
daily-research/
├── config.example.toml                  # リサーチトラック、スコアリング、出力設定（テンプレート）
├── past_topics.json                     # テーマ履歴（重複防止用、gitignored）
├── prompts/
│   ├── theme-selection-prompt.md       # Pass 1: テーマ選定指示（Opus）
│   ├── task-prompt.md                   # Pass 2: リサーチ実行指示（Sonnet）
│   └── research-protocol.md            # Pass 2: リサーチプロトコル（--append-system-prompt-file 用）
├── templates/
│   └── report-template.md              # Obsidian レポートフォーマット（frontmatter付き）
├── scripts/
│   ├── daily-research.sh               # メインエントリポイント（2パス: Opus → Sonnet）
│   └── check-auth.sh                   # OAuth 認証チェック + macOS 通知
├── com.example.daily-research.plist   # launchd スケジュール（AM 5:00）
├── tests/
│   ├── test-daily-research.bats        # ユニットテスト（構文、設定、セキュリティ）
│   └── test-e2e-mock.bats             # E2E モックテスト
├── logs/                                # 実行ログ（日付別、30日自動ローテーション）
├── docs/
│   ├── RUNBOOK.md / RUNBOOK.ja.md      # 運用ガイド
│   ├── CONTRIB.md / CONTRIB.ja.md      # 開発ガイド（本ファイル）
│   ├── plans/                           # 将来の拡張プラン
│   └── progress/                        # ポストモーテム・評価レポート
└── .claude/settings.local.json          # Claude Code プロジェクト権限設定
```

## スクリプト一覧

| スクリプト | 説明 | 使い方 |
|-----------|------|--------|
| `scripts/daily-research.sh` | メインエントリポイント。2パス実行: Pass 1（Opus テーマ選定）→ Pass 2（Sonnet リサーチ・執筆）。環境サニタイズ、認証チェック、JSON バリデーション、Sonnet フォールバックを含む。launchd が AM 5:00 に呼び出す。 | `./scripts/daily-research.sh` |
| `scripts/check-auth.sh` | `claude --version` で OAuth トークンの有効性を確認。失敗時に macOS 通知を表示。 | `./scripts/check-auth.sh` |

## 環境変数

| 変数 | 設定元 | 用途 |
|------|--------|------|
| `PATH` | plist + スクリプト | `/opt/homebrew/bin`, `/usr/local/bin`, `$HOME/.claude/local` を含む必要がある |
| `HOME` | plist | Claude CLI が認証トークンを見つけるために必要 |
| `ANTHROPIC_API_KEY` | **未設定であること** | 設定されていると Max プランではなく従量課金になる |

## 設定ファイル (`config.toml`)

| セクション | 用途 |
|-----------|------|
| `[general]` | Obsidian vault パス、出力ディレクトリ、言語、日付フォーマット |
| `[report]` | 最低出典数 |
| `[tracks.tech]` | テックトレンド: 情報源、スコアリング基準 |
| `[tracks.personal]` | パーソナル関心: 情報源、ドメイン、スコアリング基準 |
| `[user_profile]` | スキル、関心領域、目標 |

## 開発ワークフロー

### リサーチ内容を変更する場合

1. **スコアリング重み** -- `config.toml` の scoring_criteria を編集
2. **情報源** -- `config.toml` の track sources を編集
3. **レポートフォーマット** -- `templates/report-template.md` を編集
4. **リサーチの深さ・プロセス** -- `prompts/research-protocol.md` を編集
5. **テーマ選定** -- `prompts/theme-selection-prompt.md` を編集
6. **実行指示** -- `prompts/task-prompt.md` を編集

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
# research-protocol.md の手順に沿って手動で確認
```

**重要**: `claude -p` は他の Claude Code セッション内から実行できない（ネストセッションチェック）。

## テスト

```bash
# 全テスト実行
bats tests/

# テストカバー範囲:
# - スクリプト構文の妥当性 (bash -n)
# - 設定ファイルの存在確認
# - launchd plist の妥当性とスケジュール
# - ロック機構
# - ログディレクトリのパーミッション
# - past_topics.json の妥当性
# - セキュリティ（ハードコードされたキーなし、API キー未設定、ログ権限）
# - 防御的プログラミング（set -euo pipefail, trap, max-turns）
# - E2E モック: 2パスフロー、Sonnet フォールバック、JSON バリデーション
# - gtimeout/timeout 非依存の確認
```

## Claude Code CLI フラグ

### Pass 1: テーマ選定 (Opus)

| フラグ | 値 | 用途 |
|--------|---|------|
| `-p` | theme-selection-prompt.md の内容 | 非対話モード |
| `--allowedTools` | `WebSearch,WebFetch,Read,Glob,Grep` | 読み取り専用ツール（ファイル書き込み不可） |
| `--max-turns` | `15` | テーマ選定のスコープ制限 |
| `--model` | `opus` | テーマ品質のための深い推論 |
| `--output-format` | `text` | バリデーション用の生 JSON 出力 |
| `--no-session-persistence` | - | 毎回クリーンなコンテキストで実行 |

### Pass 2: リサーチ・執筆 (Sonnet)

| フラグ | 値 | 用途 |
|--------|---|------|
| `-p` | task-prompt.md の内容（+ Pass 1 成功時はテーマ JSON） | 非対話モード |
| `--append-system-prompt-file` | `prompts/research-protocol.md` | デフォルト能力を保持しつつリサーチプロトコルを注入 |
| `--allowedTools` | `WebSearch,WebFetch,Read,Write,Edit,Glob,Grep` | リサーチ・執筆用のフルツールアクセス |
| `--max-turns` | `40` | リサーチ深度の目安 |
| `--model` | `sonnet` | 速度とコスト効率 |
| `--output-format` | `json` | メタデータ付き構造化出力 |
| `--no-session-persistence` | - | 毎回クリーンなコンテキストで実行 |

## アーキテクチャ補足

2パス設計は、ブラインド LLM-as-Judge 評価で Opus のテーマ選定が +28% 優れていたことに基づく。追加コストは ~$0.30/回。詳細は `docs/progress/agent-team-evaluation.md` 参照。

タイムアウトは `--max-turns` で制御する。外部プロセスタイムアウト（gtimeout/timeout）はシグナルで claude を kill し、データ損失を引き起こすため不使用。詳細は `docs/progress/postmortem-2026-02-20.md` 参照。
