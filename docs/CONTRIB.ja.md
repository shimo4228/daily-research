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
│   ├── eval-run.sh                      # LLM-as-Judge 評価（Pass 2 成功後に実行）
│   └── check-auth.sh                   # OAuth 認証チェック + macOS 通知
├── evals/
│   ├── prompts/                         # Judge プロンプト（judge-system.md + 6次元）
│   │   ├── judge-system.md             # 共通システムプロンプト（バイアス緩和・出力形式）
│   │   ├── judge-factual.md            # Factual Grounding ルーブリック
│   │   ├── judge-depth.md              # Depth of Analysis ルーブリック
│   │   ├── judge-coherence.md          # Coherence ルーブリック
│   │   ├── judge-specificity.md        # Specificity ルーブリック
│   │   ├── judge-novelty.md            # Novelty ルーブリック
│   │   └── judge-actionability.md      # Actionability ルーブリック
│   ├── scores.jsonl                     # スコアログ（追記専用、gitignored）
│   └── scores.example.jsonl            # スキーマ参照用サンプル（Git 管理）
├── com.example.daily-research.plist   # launchd スケジュール（AM 5:00）
├── tests/
│   ├── test-daily-research.bats        # ユニットテスト（構文、設定、セキュリティ）
│   ├── test-e2e-mock.bats             # E2E モックテスト
│   ├── test-eval.bats                  # 評価フレームワークテスト
│   └── test-log-summary.bats          # log_summary パーサーテスト
├── logs/                                # 実行ログ（日付別、30日自動ローテーション）
├── docs/
│   ├── RUNBOOK.md / RUNBOOK.ja.md      # 運用ガイド
│   ├── CONTRIB.md / CONTRIB.ja.md      # 開発ガイド（本ファイル）
│   ├── MEM0-RESTORE.md                 # Mem0 復元手順
│   ├── plans/                           # 将来の拡張プラン
│   └── progress/                        # ポストモーテム・評価レポート
└── .claude/settings.local.json          # Claude Code プロジェクト権限設定
```

## スクリプト一覧

| スクリプト | 説明 | 使い方 |
|-----------|------|--------|
| `scripts/daily-research.sh` | メインエントリポイント。MCP ヘルスチェック → 2パス実行: Pass 1（Opus テーマ選定）→ Pass 2（Sonnet リサーチ・執筆 + オプショナル Mem0）。環境サニタイズ、認証チェック、MCP ヘルスチェック、JSON バリデーション、Sonnet フォールバック、Mem0 グレースフルデグラデーション、実行後の評価フックを含む。launchd が AM 5:00 に呼び出す。 | `./scripts/daily-research.sh` |
| `scripts/eval-run.sh` | LLM-as-Judge 評価。各レポートを6次元（各1-5点）で Opus が採点。Pass 2 成功後に自動呼び出し。non-fatal: 失敗してもメインスクリプトの exit code に影響しない。 | `./scripts/eval-run.sh 2026-02-21` |
| `scripts/check-auth.sh` | `claude --version` で OAuth トークンの有効性を確認。失敗時に macOS 通知を表示。 | `./scripts/check-auth.sh` |

## 環境変数

| 変数 | 設定元 | 用途 |
|------|--------|------|
| `PATH` | plist + スクリプト | `/opt/homebrew/bin`, `/usr/local/bin`, `$HOME/.claude/local` を含む必要がある |
| `HOME` | plist | Claude CLI が認証トークンを見つけるために必要 |
| `ANTHROPIC_API_KEY` | **未設定であること** | 設定されていると Max プランではなく従量課金になる |
| `CLAUDE_TIMEOUT` | スクリプト（内部） | `run_claude()` 経由の `claude -p` 呼び出しのタイムアウト（秒）。0 = 無制限。MCP ヘルスチェックは 60秒、Pass 2 は 900秒 |
| `DEBUG` | ユーザー設定 | `1` に設定するとデバッグログ（PATH、CLAUDE_CMD）を出力 |

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
# - スクリプト構文の妥当性 (bash -n): daily-research.sh と eval-run.sh 両方
# - 設定ファイルの存在確認
# - launchd plist の妥当性とスケジュール
# - ロック機構
# - ログディレクトリのパーミッション
# - past_topics.json の妥当性
# - セキュリティ（ハードコードされたキーなし、API キー未設定、ログ権限）
# - 防御的プログラミング（set -euo pipefail, trap, max-turns）
# - E2E モック: 2パスフロー、Sonnet フォールバック、JSON バリデーション
# - gtimeout/timeout 非依存の確認
# - 評価フレームワーク: judge プロンプトファイル、プレースホルダ、バイアス緩和指示
# - scores.example.jsonl スキーマバリデーション
# - eval-run.sh 統合フック（daily-research.sh 内の呼び出し確認）
# - log_summary パーサー: NDJSON、プレーン JSON、配列 JSON、不正入力の処理
```

## Claude Code CLI フラグ

### Pass 1: テーマ選定 (Opus)

| フラグ | 値 | 用途 |
|--------|---|------|
| `-p` | theme-selection-prompt.md の内容 | 非対話モード |
| `--permission-mode` | `default` | デフォルトの権限処理を使用 |
| `--allowedTools` | `WebSearch,WebFetch,Read,Glob,Grep` | 読み取り専用ツール（ファイル書き込み不可） |
| `--max-turns` | `15` | テーマ選定のスコープ制限 |
| `--model` | `opus` | テーマ品質のための深い推論 |
| `--output-format` | `stream-json` | NDJSON ストリーム。インライン Python で result + ツール使用数を抽出 |
| `--verbose` | - | 詳細なイベントストリームを含む |
| `--no-session-persistence` | - | 毎回クリーンなコンテキストで実行 |

### Pass 2: リサーチ・執筆 (Sonnet)

| フラグ | 値 | 用途 |
|--------|---|------|
| `-p` | task-prompt.md の内容（+ Pass 1 成功時はテーマ JSON） | 非対話モード |
| `--permission-mode` | `default` | デフォルトの権限処理を使用 |
| `--append-system-prompt-file` | `prompts/research-protocol.md` | デフォルト能力を保持しつつリサーチプロトコルを注入 |
| `--allowedTools` | `WebSearch,WebFetch,Read,Write,Edit,Glob,Grep[,mcp__mem0__*]` | リサーチ・執筆用のフルツールアクセス。Mem0 ツール（`mcp__mem0__search-memories`, `mcp__mem0__add-memory`）は MCP ヘルスチェック成功時のみ追加 |
| `--max-turns` | `40` | リサーチ深度の目安 |
| `--model` | `sonnet` | 速度とコスト効率 |
| `--output-format` | `json` | メタデータ付き構造化出力 |
| `--no-session-persistence` | - | 毎回クリーンなコンテキストで実行 |

**備考**: 全 `claude -p` 呼び出しは `run_claude()` ラッパー経由で `< /dev/null` stdin リダイレクトを使用する。これにより MCP の stdio 通信がターミナルの stdin と競合するのを防止する（MCP ハングの根本原因だった）。

## アーキテクチャ補足

2パス設計は、ブラインド LLM-as-Judge 評価で Opus のテーマ選定が +28% 優れていたことに基づく。追加コストは ~$0.30/回。詳細は `docs/progress/agent-team-evaluation.md` 参照。

タイムアウトは `--max-turns` で制御する。外部プロセスタイムアウト（gtimeout/timeout）はシグナルで claude を kill し、データ損失を引き起こすため不使用。詳細は `docs/progress/postmortem-2026-02-20.md` 参照。

## Mem0 MCP 統合

パイプラインはオプショナルで [Mem0](https://mem0.ai) を MCP（Model Context Protocol）経由で統合し、リサーチセッション間の永続メモリを提供する。

### 動作の流れ

1. **MCP ヘルスチェック**（Pass 1 前）: Haiku プローブ（`"Say OK"`、60秒タイムアウト）で MCP サーバーの応答を確認。失敗してもパイプラインは Mem0 なしで続行（非致命的）。

2. **Pass 2 — メモリ検索**（research-protocol.md の Step 1.5）: Sonnet が `mcp__mem0__search-memories` を呼び出し、過去のリサーチセッションからコンテキストを取得。

3. **Pass 2 — メモリ記録**（research-protocol.md の Step 6）: レポート書き込み後、Sonnet が `mcp__mem0__add-memory` を呼び出し、主要な知見を将来のセッション用に保存。

### グレースフルデグラデーション

- MCP ヘルスチェック失敗時: `MEM0_AVAILABLE=false`、Mem0 ツールを `--allowedTools` から除外
- Mem0 ツールが利用可能でも Pass 2 中に失敗した場合: research-protocol.md の指示に従いスキップして続行
- Mem0 の使用有無にかかわらず、レポートの構造は同一

### stdin リダイレクト (`< /dev/null`)

全 `claude -p` 呼び出しは `run_claude()` ラッパー経由で stdin を `/dev/null` からリダイレクトする。これにより MCP の stdio ベースの通信がターミナルの stdin と競合するのを防止する（MCP 初期化ハングの根本原因だった）。調査の経緯は `docs/progress/` を参照。

## 評価フレームワーク (LLM-as-Judge)

Pass 2 が正常完了した後、`daily-research.sh` は `scripts/eval-run.sh` を non-fatal フックとして呼び出す。評価が失敗してもメインスクリプトの exit code には影響しない。

### 動作の流れ

1. `eval-run.sh` は第1引数で日付を受け取る（省略時は当日）
2. DATE フォーマットを検証（`YYYY-MM-DD` 正規表現）してパス横断を防止
3. `config.toml` から `vault_path` と `output_dir` を python3（stdin 経由）で読み取り
4. 出力ディレクトリから `{DATE}_*.md` にマッチするレポートを検出
5. 各レポートについて 6 次元の Opus judge を独立実行
6. 2段階パーサー（直接 JSON パース → `raw_decode` フォールバック）でスコアを抽出
7. `evals/scores.jsonl` に JSONL エントリを追記

### 6つの評価次元

| 次元 | JSONL キー | 評価内容 |
|------|-----------|---------|
| Factual Grounding | `factual_grounding` | 出典の質、引用数、主張の検証度 |
| Depth of Analysis | `depth_of_analysis` | 表面的な要約を超えた分析の深さ |
| Coherence | `coherence` | 論理的な流れ、構成、読みやすさ |
| Specificity | `specificity` | 具体的なツール名・数字・事例 vs 抽象的な記述 |
| Novelty | `novelty` | 一般的な知識を超えた新しい洞察 |
| Actionability | `actionability` | 実践的で実装可能な開発アイデア |

各次元 1-5 点（1レポートあたり合計 30 点満点）。

### Judge の設定

| フラグ | 値 | 用途 |
|--------|---|------|
| `--append-system-prompt-file` | `evals/prompts/judge-system.md` | バイアス緩和 + 出力形式 |
| `--max-turns` | `3` | ツール呼び出しループの防止 |
| `--model` | `claude-opus-4-6` | 品質判断のための深い推論 |
| `--output-format` | `json` | スコア抽出用の構造化出力 |

### スコアログのスキーマ (`scores.jsonl`)

```json
{
  "date": "2026-02-21",
  "pipeline_version": "2pass-opus-sonnet",
  "track": "tech",
  "slug": "xcode-26-agentic-coding-mcp",
  "scores": {
    "factual_grounding": 4,
    "depth_of_analysis": 3,
    "coherence": 5,
    "specificity": 4,
    "novelty": 3,
    "actionability": 4
  },
  "total": 23,
  "judge_model": "claude-opus-4-6",
  "eval_duration_s": 42
}
```

### パイプラインバージョン

`eval-run.sh` の `PIPELINE_VERSION` 変数はパイプライン構成を追跡する。パイプラインに機能変更（モデル変更、プロンプト構造変更、実行フロー変更など）を加えた際に手動で更新する。これによりスコア分析での前後比較が可能になる。

**統計規律**: n < 20 のサンプルでの比較は「暫定シグナル」に過ぎない。バージョン比較は n >= 20 から有効とみなす。

### 入力バリデーション

`eval-run.sh` は以下の安全性チェックを含む:
- DATE フォーマットの検証（`YYYY-MM-DD` 正規表現）によるパス横断防止
- テーマ JSON のテーマ名・選定理由の文字数上限チェック（200文字・500文字）
- スコア範囲の検証（1-5 の整数）
- 不正な judge 出力に対する2段階スコア抽出での graceful なハンドリング
