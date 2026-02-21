# daily-research

Claude Code 非対話モード (`claude -p`) + macOS launchd で毎朝 AM 5:00 に自律リサーチレポートを生成し、Obsidian vault に保存するシステム。

## Tech Stack

- Shell script (Bash) — Python ゼロ、外部依存ゼロ
- Claude Code CLI (`claude -p`) — 非対話モード
- TOML — 設定ファイル (`config.toml`)
- launchd — macOS スケジューラ
- bats — シェルテストフレームワーク

## Directory Structure

```
daily-research/
├── scripts/
│   ├── daily-research.sh       # メインエントリポイント（Opus テーマ選定 → Sonnet リサーチ）
│   └── check-auth.sh           # OAuth トークンのヘルスチェック
├── prompts/
│   ├── theme-selection-prompt.md # Pass 1: Opus テーマ選定プロンプト
│   ├── task-prompt.md            # Pass 2: Sonnet リサーチ・執筆タスク指示
│   └── research-protocol.md     # Pass 2: リサーチプロトコル（品質の中核）
├── templates/
│   └── report-template.md      # レポートの Markdown テンプレート（YAML frontmatter 付き）
├── config.toml                 # リサーチトラック・スコアリング基準・出力設定（.gitignore）
├── config.example.toml         # config.toml のテンプレート（Git 管理）
├── past_topics.json            # 過去テーマの重複排除用（.gitignore）
├── logs/                       # 実行ログ（30日でローテーション、.gitignore）
├── evals/
│   ├── prompts/                    # LLM-as-Judge プロンプト（judge-system.md + 6次元）
│   ├── scores.jsonl                # スコアログ（追記専用、.gitignore）
│   └── scores.example.jsonl       # スキーマ参照用サンプル（Git 管理）
├── tests/
│   ├── test-daily-research.bats     # 構文・設定・セキュリティテスト
│   ├── test-e2e-mock.bats          # E2E モックテスト
│   └── test-eval.bats              # 評価フレームワークテスト
├── docs/
│   ├── RUNBOOK.md / RUNBOOK.ja.md   # 運用ガイド
│   ├── CONTRIB.md / CONTRIB.ja.md   # 開発ガイド
│   ├── MEM0-RESTORE.md              # Mem0 復元手順
│   ├── plans/                       # 将来の拡張プラン（eval-framework-plan.md など）
│   └── progress/                    # ポストモーテム・評価レポート
└── com.example.daily-research.plist  # launchd plist テンプレート
```

## Build / Test / Run

```bash
# 手動実行（別ターミナルで。Claude Code セッションと同じターミナルでは不可）
./scripts/daily-research.sh

# 認証確認
./scripts/check-auth.sh

# テスト
bats tests/

# launchd 登録
cp com.example.daily-research.plist com.daily-research.plist
# → YOUR_USERNAME を編集
ln -sf "$(pwd)/com.daily-research.plist" ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.daily-research.plist

# ログ確認
tail -f logs/$(date +%Y-%m-%d).log
```

## Conventions

### 設計方針

- **2パス方式**: Pass 1 (Opus テーマ選定) → Pass 2 (Sonnet リサーチ・執筆)
- Pass 1 失敗時は Sonnet が従来通りテーマ選定も担当（フォールバック）
- **`--append-system-prompt-file`** を使用（`--system-prompt-file` ではない）。Claude Code のデフォルト能力を保持するため
- **`--allowedTools`** で最小権限。`--dangerously-skip-permissions` は使わない
  - Pass 1 (Opus): WebSearch, WebFetch, Read, Glob, Grep
  - Pass 2 (Sonnet): WebSearch, WebFetch, Read, Write, Edit, Glob, Grep
- **シェルスクリプトのみ** で構成。Python や追加フレームワークは導入しない

### 設定ファイル

- `config.toml` と `past_topics.json` は個人データのため `.gitignore` に含まれる
- Git に含まれるのは `config.example.toml` と `past_topics.example.json`
- 設定を変更する場合は `config.toml` を直接編集する（example は公開テンプレート）

### レポート出力

- 出力先: `{vault_path}/{output_dir}/{date}_{track}_{slug}.md`
- vault_path は `config.toml` の `[general].vault_path` で指定
- レポートは散文主体。箇条書きは比較表や4項目以上の並列列挙のみ
- 出典は最低5件、URL 必須

### プロンプト編集時の注意

- `prompts/theme-selection-prompt.md` がテーマ選定の指示（Pass 1）
- `prompts/research-protocol.md` がリサーチの質を決める中核ファイル（Pass 2）
- `templates/report-template.md` は出力フォーマットの定義
- プロンプトファイルは全て日本語。出力言語の変更は protocol.md を修正

### 評価フレームワーク (LLM-as-Judge)

- **eval-run.sh**: Pass 2 成功後に自動実行。2記事 × 6次元 = 12 Opus calls/日
- **6次元ルーブリック**: Factual Grounding / Depth / Coherence / Specificity / Novelty / Actionability（各1-5点、30点満点）
- **スコアログ**: `evals/scores.jsonl` に追記（.gitignore）。スキーマは `scores.example.jsonl` を参照
- **pipeline_version**: 機能変更時に `eval-run.sh` の `PIPELINE_VERSION` 変数を手動で更新する
- **統計規律**: n < 20 の比較は「暫定シグナル」。バージョン比較は n ≥ 20 から有効とみなす
- 評価失敗は daily-research.sh の exit code に影響しない（non-fatal）

### 過去に試行・棚上げした機能

- **エージェントチーム版**: コスト・時間対効果が低く棄却。詳細は `docs/progress/` のポストモーテム参照。コードは git history (`a79074e`) で復元可能
- **Mem0 永続メモリ**: MCP 初期化ハングのため棚上げ。復元手順は `docs/MEM0-RESTORE.md`

## Status

- 本番稼働中。毎朝 AM 5:00 に launchd で自動実行
- Opus テーマ選定 + Sonnet リサーチ・執筆の2パス方式（E2E 検証済み、2026-02-20）
- Pass 1 失敗時は Sonnet 一括フォールバックで継続稼働
