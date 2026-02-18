# Progress Checkpoint — 2026-02-18 エージェントチーム版実装

## 現在のタスク
エージェントチーム版デイリーリサーチの実装（Opus 司令塔 + Sonnet 実働）

## 完了した作業
- プロジェクト全体の調査（既存スクリプト、プロンプト、設定、テンプレートの把握）
- Claude Code CLI のマルチモデル・サブエージェント機能の調査
- 実装計画の策定・ユーザー承認
- Git worktree 作成済み: `feat/agent-team` ブランチ → `../daily-research-agent-team/`

## Git Worktree 情報
- **ブランチ**: `feat/agent-team`（`main` の `df453d9` から分岐）
- **worktree パス**: `/Users/shimomoto_tatsuya/MyAI_Lab/daily-research-agent-team/`
- **本番 (main)**: `/Users/shimomoto_tatsuya/MyAI_Lab/daily-research/` — 変更なし

## 残りの作業（全て worktree 内で実施）

### Task 1: エージェント定義ファイル 3 本作成
- `.claude/agents/team-orchestrator.md` — model: opus, tools: Task(team-researcher, team-writer), Read, Write, WebSearch, WebFetch, Glob, Grep
- `.claude/agents/team-researcher.md` — model: sonnet, tools: WebSearch, WebFetch, Read
- `.claude/agents/team-writer.md` — model: sonnet, tools: Read, Write

### Task 2: プロンプトファイル 2 本作成
- `prompts/team-task-prompt.md` — claude -p に渡す指示（既存 task-prompt.md と同構造）
- `prompts/team-protocol.md` — --append-system-prompt-file で追加する詳細プロトコル（Step 1-6）

### Task 3: シェルスクリプト作成
- `scripts/agent-team-research.sh` — 既存 daily-research.sh のパターンを踏襲、`--agent team-orchestrator` + `--allowedTools` に Task 追加、タイムアウト 2700 秒

### Task 4: チェーン実行追加（Task 3 完了後）
- `scripts/daily-research.sh` 末尾の `exit $EXIT_CODE` 前にチェーン呼び出しコード追加
- チーム版失敗は既存パイプラインの終了コードに影響しない

### Task 5: 設定・テスト（Task 1, 3 完了後）
- `config.example.toml` に `[team]` セクション追加
- `tests/test-agent-team.bats` 新規作成

### Task 6: ドキュメント更新（Task 1, 2, 3 完了後）
- `CLAUDE.md` のディレクトリ構造と Conventions を更新

## 重要な判断
- **サブエージェント方式を採用**（実験的 Agent Teams ではなく安定した Task ツール経由）
- **Opus 司令塔 + Sonnet 実働**: Opus はテーマ選定・委任・検証のみ (15-20 ターン)、Sonnet が検索 (20-25 ターン×2) と執筆 (10-15 ターン×2) を担当
- **逐次実行**: 既存 Sonnet 版 → チーム版の順。past_topics.json の整合性を保つ
- **ファイル名規則**: 既存=`{date}_{track}_{slug}.md` / チーム=`{date}_{track}_team_{slug}.md`
- **`--agent` + `--append-system-prompt-file` の併用**: Phase 4 で要検証

## 詳細計画ファイル
`~/.claude/plans/wise-frolicking-puppy.md` に完全な実装計画あり

## アーキテクチャ図
```
launchd (AM 5:00)
  └─ daily-research.sh
       ├─ [既存] claude -p --model sonnet → 2 記事
       │    └─ past_topics.json 更新
       └─ [新規] agent-team-research.sh（チェーン実行）
            └─ claude -p --agent team-orchestrator (Opus)
                 ├─ config.toml / past_topics.json / template 読込
                 ├─ WebSearch x6-8 → テーマ選定
                 ├─ Task → team-researcher (Sonnet) × 2 [並列]
                 ├─ Task → team-writer (Sonnet) × 2 [並列]
                 ├─ 保存ファイル検証
                 └─ past_topics.json 更新
```

## 参考: 既存ファイルの重要ポイント
- `scripts/daily-research.sh`: L98-105 が claude 呼び出し、L122 が `exit $EXIT_CODE`（チェーン挿入箇所）
- `prompts/research-protocol.md`: Step 1-8 の詳細プロトコル（チーム版のベース）
- `config.example.toml`: tracks.tech / tracks.personal のスコアリング基準
- `templates/report-template.md`: YAML frontmatter + 6 セクション構成
