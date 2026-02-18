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
├── .claude/agents/
│   ├── team-orchestrator.md    # チーム版司令塔エージェント（Opus）
│   ├── team-researcher.md      # チーム版調査エージェント（Sonnet）
│   └── team-writer.md          # チーム版執筆エージェント（Sonnet）
├── scripts/
│   ├── daily-research.sh       # メインエントリポイント（launchd が実行、チーム版もチェーン呼出）
│   ├── agent-team-research.sh  # チーム版エントリポイント（Opus 司令塔 + Sonnet 実働）
│   └── check-auth.sh           # OAuth トークンのヘルスチェック
├── prompts/
│   ├── task-prompt.md           # 既存版 claude -p に渡すタスク指示
│   ├── research-protocol.md    # 既存版リサーチプロトコル
│   ├── team-task-prompt.md     # チーム版タスク指示
│   └── team-protocol.md        # チーム版リサーチプロトコル
├── templates/
│   └── report-template.md      # レポートの Markdown テンプレート（YAML frontmatter 付き）
├── config.toml                 # リサーチトラック・スコアリング基準・出力設定（.gitignore）
├── config.example.toml         # config.toml のテンプレート（Git 管理）
├── past_topics.json            # 過去テーマの重複排除用（.gitignore）
├── logs/                       # 実行ログ（30日でローテーション、.gitignore）
├── tests/
│   ├── test-daily-research.bats
│   └── test-agent-team.bats    # チーム版テスト
├── docs/
│   ├── RUNBOOK.md / RUNBOOK.ja.md    # 運用ガイド
│   └── CONTRIB.md / CONTRIB.ja.md    # 開発ガイド
└── com.example.daily-research.plist  # launchd plist テンプレート
```

## Build / Test / Run

```bash
# 手動実行（既存版のみ）
./scripts/daily-research.sh

# チーム版のみ手動実行
./scripts/agent-team-research.sh

# 認証確認
./scripts/check-auth.sh

# テスト
bats tests/

# launchd 登録
cp com.example.daily-research.plist com.daily-research.plist
# → YOUR_USERNAME を編集
ln -sf "$(pwd)/com.daily-research.plist" ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.daily-research.plist

# ログ確認（既存版）
tail -f logs/$(date +%Y-%m-%d).log
# ログ確認（チーム版）
tail -f logs/$(date +%Y-%m-%d)-team.log
```

## Conventions

### 設計方針

- **`--append-system-prompt-file`** を使用（`--system-prompt-file` ではない）。Claude Code のデフォルト能力を保持するため
- **`--allowedTools`** で最小権限。`--dangerously-skip-permissions` は使わない
  - 既存版: WebSearch, WebFetch, Read, Write, Glob, Grep
  - チーム版: 上記 + Task（サブエージェント委任用）
- **シェルスクリプトのみ** で構成。Python や追加フレームワークは導入しない

### エージェントチーム版

- **Opus 司令塔 + Sonnet 実働**: Opus がテーマ選定・委任・検証、Sonnet がリサーチ・執筆を担当
- **チェーン実行**: 既存 Sonnet 版完了後に自動実行。チーム版の失敗は既存パイプラインに影響しない
- **past_topics.json の整合性**: 逐次実行のため競合なし。バックアップも分離（`.bak` / `.team.bak`）

### 設定ファイル

- `config.toml` と `past_topics.json` は個人データのため `.gitignore` に含まれる
- Git に含まれるのは `config.example.toml` と `past_topics.example.json`
- 設定を変更する場合は `config.toml` を直接編集する（example は公開テンプレート）

### レポート出力

- 既存版出力先: `{vault_path}/{output_dir}/{date}_{track}_{slug}.md`
- チーム版出力先: `{vault_path}/{output_dir}/{date}_{track}_team_{slug}.md`
- vault_path は `config.toml` の `[general].vault_path` で指定
- レポートは散文主体。箇条書きは比較表や4項目以上の並列列挙のみ
- 出典は最低5件、URL 必須

### プロンプト編集時の注意

- 既存版: `prompts/research-protocol.md` がリサーチの質を決める中核ファイル
- チーム版: `prompts/team-protocol.md` + `.claude/agents/team-*.md` が品質を決める
- `templates/report-template.md` は両版で共有する出力フォーマットの定義
- プロンプトファイルは全て日本語。出力言語の変更は各 protocol.md を修正

## Status

- 既存版: 本番稼働中。毎朝 AM 5:00 に自動実行
- チーム版: 実装完了、手動テスト待ち。`--agent` + `--append-system-prompt-file` の併用互換性を要検証
