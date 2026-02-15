# 開発ガイド

> 正式な情報源: `config.example.toml`, `scripts/*.sh`, `com.example.daily-research.plist`

## 前提条件

| ツール | 用途 | インストール |
|--------|------|-------------|
| Claude Code CLI | コア実行エンジン | `brew install claude` or [docs.anthropic.com](https://docs.anthropic.com) |
| Claude Max プラン | API追加課金なしで利用 | サブスクリプション契約が必要 |
| macOS (launchd) | スケジューラ | OS組み込み |
| bats-core | シェルテストフレームワーク | `brew install bats-core` |
| shellcheck | シェルスクリプト静的解析 | `brew install shellcheck` |

## プロジェクト構成

```
daily-research/
├── config.example.toml                  # リサーチトラック、スコアリング、出力設定（テンプレート）
├── past_topics.json                     # テーマ履歴（重複防止用、gitignored）
├── prompts/
│   ├── task-prompt.md                   # 実行指示（claude -p の引数）
│   └── research-protocol.md            # リサーチプロトコル（--append-system-prompt-file 用）
├── templates/
│   └── report-template.md              # Obsidian レポートフォーマット（frontmatter付き）
├── scripts/
│   ├── daily-research.sh               # メインラッパー（launchd エントリポイント）
│   └── check-auth.sh                   # OAuth 認証チェック + macOS 通知
├── com.example.daily-research.plist   # launchd スケジュール（AM 5:00）
├── tests/
│   └── test-daily-research.bats        # シェルテスト（構文、設定、セキュリティ）
├── logs/                                # 実行ログ（日付別、30日自動ローテーション）
├── docs/
│   ├── plans/plan-a-implementation.md   # 正式な設計ドキュメント
│   └── archive/                         # 過去の設計ドキュメント
└── .claude/settings.local.json          # Claude Code プロジェクト権限設定
```

## スクリプト一覧

| スクリプト | 説明 | 使い方 |
|-----------|------|--------|
| `scripts/daily-research.sh` | メインスクリプト。環境サニタイズ、認証チェック、`claude -p` でリサーチプロトコル実行、結果をログに記録。launchd が AM 5:00 に呼び出す。 | `./scripts/daily-research.sh` |
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
5. **実行指示** -- `prompts/task-prompt.md` を編集

### 実行処理を変更する場合

1. `scripts/daily-research.sh` を編集
2. 構文チェック: `bash -n scripts/daily-research.sh`
3. 静的解析: `shellcheck scripts/daily-research.sh`
4. テスト実行: `bats tests/test-daily-research.bats`
5. 手動テスト（launchd 環境を模倣）:
   ```bash
   env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
     /bin/bash scripts/daily-research.sh
   ```

### プロンプトを対話的にテストする場合

```bash
cd ~/MyAI_Lab/daily-research
CLAUDECODE= claude  # ネストセッションチェックをバイパス
# research-protocol.md の手順に沿って手動で確認
```

## テスト

```bash
# 全テスト実行
bats tests/test-daily-research.bats

# テストカバー範囲:
# - スクリプト構文の妥当性 (bash -n)
# - 設定ファイルの存在確認
# - launchd plist の妥当性とスケジュール
# - ロック機構
# - ログディレクトリのパーミッション
# - past_topics.json の妥当性
# - セキュリティ（ハードコードされたキーなし、API キー未設定、ログ権限）
# - 防御的プログラミング（set -euo pipefail, trap, timeout）
```

## Claude Code CLI フラグ

`daily-research.sh` で使用:

| フラグ | 値 | 用途 |
|--------|---|------|
| `-p` | task-prompt.md の内容 | 非対話モード |
| `--append-system-prompt-file` | `prompts/research-protocol.md` | デフォルト能力を保持しつつリサーチプロトコルを注入 |
| `--allowedTools` | `WebSearch,WebFetch,Read,Write,Glob,Grep` | これらのツールを自動承認 |
| `--max-turns` | `40` | ターン数の目安（厳密な制限ではない） |
| `--model` | `sonnet` | モデル選択 |
| `--output-format` | `json` | 構造化出力 |
| `--no-session-persistence` | - | 毎回クリーンなコンテキストで実行 |
