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
│   ├── daily-research.sh       # メインエントリポイント（launchd が実行）
│   └── check-auth.sh           # OAuth トークンのヘルスチェック
├── prompts/
│   ├── task-prompt.md           # claude -p に渡すタスク指示
│   └── research-protocol.md    # --append-system-prompt-file で追加するリサーチプロトコル
├── templates/
│   └── report-template.md      # レポートの Markdown テンプレート（YAML frontmatter 付き）
├── config.toml                 # リサーチトラック・スコアリング基準・出力設定（.gitignore）
├── config.example.toml         # config.toml のテンプレート（Git 管理）
├── past_topics.json            # 過去テーマの重複排除用（.gitignore）
├── logs/                       # 実行ログ（30日でローテーション、.gitignore）
├── tests/
│   └── test-daily-research.bats
├── docs/
│   ├── RUNBOOK.md / RUNBOOK.ja.md    # 運用ガイド
│   └── CONTRIB.md / CONTRIB.ja.md    # 開発ガイド
└── com.example.daily-research.plist  # launchd plist テンプレート
```

## Build / Test / Run

```bash
# 手動実行（テスト用）
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

- **`--append-system-prompt-file`** を使用（`--system-prompt-file` ではない）。Claude Code のデフォルト能力を保持するため
- **`--allowedTools`** で最小権限（WebSearch, WebFetch, Read, Write, Glob, Grep のみ）。`--dangerously-skip-permissions` は使わない
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

- `prompts/research-protocol.md` がリサーチの質を決める中核ファイル
- `templates/report-template.md` は出力フォーマットの定義
- 両ファイルとも日本語。出力言語の変更は `research-protocol.md` の10行目を修正

## Status

本番稼働中。毎朝 AM 5:00 に自動実行。
