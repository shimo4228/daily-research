# Plan A 詳細実装計画 — Claude Code 単体オーケストレーター方式

作成日: 2026-02-14

## 概要

### What
Claude Code の非対話モード（`claude -p`）に `--append-system-prompt-file` でリサーチプロトコルを注入し、テーマ選定からレポート出力まで**単一プロセス内で自律完結**させる。

### Why
- **最もシンプル**: 外部CLIやAPIへの依存ゼロ。Claude Code + Maxプランだけで完結
- **コストゼロ**: Maxプラン定額内。APIキーを使わないため追加課金なし
- **保守容易**: シェルスクリプト1本 + プロンプトファイル群のみ。Pythonコード不要
- **エージェント自律性**: 途中で「情報が足りない」と判断したら追加検索できる

### Alternatives considered
- Plan B（マルチCLI方式）: Gemini CLI追加で検索品質は上がるが、認証管理2つ・Python実装が必要で複雑性が増す
- OpenAI Deep Research API: $1.3〜$3.4/回（月$78〜$204）でコスト不可
- Python + 各社API直接呼び出し: Maxプラン恩恵を受けられない

---

## CLI仕様の訂正（比較ドキュメントからの修正点）

調査の結果、`implementation-plans-comparison.md` に記載された以下のCLI仕様は**不正確**であることが判明した:

| 比較ドキュメントの記述 | 実際の仕様 | 対応 |
|---|---|---|
| `claude -p "/daily-research"` | `/skill-name` 構文は非対話モードで**動作しない** | `--append-system-prompt-file` でプロトコル注入 |
| `--permission-mode bypassPermissions` | `bypassPermissions` は無効な値 | `--dangerously-skip-permissions` を使用 |
| Skill経由での起動 | Skillは自動検出可能だが明示起動は不可 | システムプロンプト追記方式に変更 |

---

## アーキテクチャ（修正版）

```
launchd (AM 5:00)
    ↓
scripts/daily-research.sh（環境サニタイズ + 認証チェック）
    ↓
claude -p "$(cat prompts/task-prompt.md)" \
  --append-system-prompt-file prompts/research-protocol.md \
  --allowedTools "WebSearch,WebFetch,Read,Write,Glob,Grep" \
  --dangerously-skip-permissions \
  --max-turns 40 \
  --model sonnet \
  --output-format json \
  --no-session-persistence
    ↓
Claude Code が research-protocol.md に従い自律実行:
  [1] config.toml 読み込み + past_topics.json 重複チェック
  [2] WebSearch でテーマソース巡回 → 候補スコアリング → 2テーマ選定
  [3] 各テーマに最適化したリサーチ問いを動的生成
  [4] 多段階リサーチ（WebSearch × 10-20回 + WebFetch で一次情報取得）
  [5] レポート構成・執筆（3000字 × 2本）
  [6] Obsidian vault に Write ツールで直接保存
  [7] past_topics.json を更新
    ↓
logs/ に実行結果を記録
```

---

## プロジェクト構成

```
daily-research/
├── PLAN.md                              # ← 既存（更新する）
├── config.toml                          # テーマソース、出力先等の設定
├── past_topics.json                     # テーマ履歴（重複防止）
├── prompts/
│   ├── research-protocol.md             # リサーチプロトコル全体（--append-system-prompt-file用）
│   └── task-prompt.md                   # 実行指示（claude -p の引数）
├── templates/
│   └── report-template.md               # レポートフォーマット定義
├── scripts/
│   ├── daily-research.sh                # launchdから呼ばれるラッパー
│   └── check-auth.sh                    # OAuth認証状態チェック + 通知
├── com.shimomoto.daily-research.plist   # launchd設定
├── logs/                                # 実行ログ（日付別）
├── docs/
│   ├── implementation-plans-comparison.md  # ← 既存
│   └── plan-a-implementation.md         # ← 本ドキュメント
├── SESSION_HANDOFF.md                   # ← 既存
└── .claude/
    └── settings.local.json              # ← 既存
```

**注意**: Pythonプロジェクト構成（`pyproject.toml`, `src/` 等）は**不要**。シェルスクリプト + プロンプトファイルのみで完結する。

---

## 各フェーズの実装詳細

### Phase 1: 設定ファイル作成

#### 1-1. `config.toml`

**What**: テーマソース、出力先、レポート設定を一元管理する設定ファイル。
**Why**: プロンプトにハードコードせず、設定変更を容易にするため。Claude に Read させて参照させる。

```toml
[general]
vault_path = "/Users/shimomoto_tatsuya/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault"
output_dir = "daily-research"
language = "ja"
date_format = "%Y-%m-%d"

[report]
max_chars = 3000
min_sources = 5

[tracks.tech]
name = "テックトレンド"
focus = "開発者向けテクノロジートレンド。新しいツール、フレームワーク、AI、OSS"
sources = [
  "Hacker News トップ記事",
  "GitHub Trending (直近7日)",
  "TechCrunch AI/Apps カテゴリ",
  "arXiv cs.AI, cs.CL, cs.SE 新着",
]
scoring_criteria = [
  { name = "新規性", weight = 30, desc = "past_topics.json に類似テーマがないか" },
  { name = "変化の兆し", weight = 25, desc = "静的知識ではなく動いている領域か" },
  { name = "開発可能性", weight = 25, desc = "Python/Swift/TypeScriptで何か作れそうか" },
  { name = "ウィスパートレンド度", weight = 20, desc = "まだ多くの人が気づいていない変化か" },
]

[tracks.personal]
name = "パーソナル関心"
focus = "身体性認知科学・仏教の最新研究や実践"
sources = [
  "Semantic Scholar (embodied cognition, mindfulness)",
  "arXiv q-bio.NC 新着",
  "Lion's Roar 最新記事",
  "Tricycle 最新記事",
  "Mindful Magazine 最新記事",
]
domains = ["身体性認知科学", "Embodied Cognition", "仏教", "瞑想", "マインドフルネス"]
scoring_criteria = [
  { name = "新規性", weight = 25, desc = "past_topics.json に類似テーマがないか" },
  { name = "変化の兆し", weight = 20, desc = "静的知識ではなく動いている領域か" },
  { name = "開発可能性", weight = 20, desc = "Python/Swift/TypeScriptで何か作れそうか" },
  { name = "ウィスパートレンド度", weight = 15, desc = "まだ多くの人が気づいていない変化か" },
  { name = "テック×身体性の交差点", weight = 20, desc = "テクノロジーと身体性の接点があるか" },
]

[user_profile]
skills = ["Python", "Swift", "TypeScript", "iOS開発"]
interests = ["AI/ML", "エージェント", "身体性認知科学", "仏教", "瞑想"]
goal = "次に自分が作るべき開発プロジェクトのアイデアを発見する"
```

#### 1-2. `past_topics.json`（初期状態）

**What**: 過去のテーマ履歴。重複防止に使用。
**Why**: 毎日テーマが重複しないよう、Claudeが参照・更新する。

```json
{
  "version": 1,
  "topics": []
}
```

各エントリのスキーマ:
```json
{
  "date": "2026-02-14",
  "track": "tech",
  "topic": "MCPサーバーエコシステムの急成長",
  "tags": ["AI", "MCP", "開発ツール"],
  "filename": "2026-02-14_tech_mcp-server-ecosystem.md"
}
```

#### 1-3. `templates/report-template.md`

**What**: レポートの統一フォーマット定義。
**Why**: Claude にこのテンプレートを参照させ、出力品質を安定させる。

```markdown
---
date: {date}
category: {track}  # "tech" or "personal"
tags: [{tag1}, {tag2}, ...]
topic: "{topic_title}"
sources: {source_count}
---

# {topic_title}

## なぜ今このテーマか
（このトピックが注目に値する理由。2-3文）

## 背景
（このトピックの文脈・歴史）

## 現在の状況
（最新の動向。具体的なツール名、数字、事例）

## 注目プレイヤー
（主要な企業・プロジェクト・人物）

## 開発アイデアへの示唆
- **アイデア1**: 〇〇を作ると△△な価値がある
  - 技術的実現性: ★★★☆☆
  - 需要の見込み: ★★★★☆
  - 自分のスキルとの相性: Python/TypeScript/Swift
- **アイデア2**: ...

## ソース
- [タイトル](URL)
- ...
```

---

### Phase 2: プロンプト設計（最重要フェーズ）

**Why このフェーズが最重要か**: SESSION_HANDOFF.md に記録されている通り、「テーマ選定とプロンプトの品質がシステム全体の価値を決める」。ここが弱いと表面的なレポートが量産されるだけになる。

#### 2-1. `prompts/research-protocol.md`（システムプロンプト追記）

**What**: `--append-system-prompt-file` で注入するリサーチプロトコル全体。Claudeのデフォルト能力は保持しつつ、リサーチャーとしての行動指針を追加する。
**Why**: `--system-prompt-file`（全置換）ではなく `--append-system-prompt-file`（追記）を使うことで、Claude Code のデフォルトのツール利用能力・判断力を維持する。

```markdown
# 自律型ディープリサーチ・プロトコル

## あなたの役割

あなたは主席リサーチャーとして、以下のプロトコルに厳密に従って調査を実行する。
目的は「ユーザーが次に作るべき開発プロジェクトのアイデア発見」を支援すること。

## 重要な制約

- 日本語で全て出力すること
- 各レポートは3000字前後（2500〜3500字の範囲）
- 出典は最低5件、URLを含めること
- past_topics.json に記録済みのテーマは避けること（30日以内の類似テーマ）
- 30日以上前の類似テーマは「新展開がある場合のみ」再訪可

## 実行手順

### Step 1: 設定読み込み

1. Read ツールで `config.toml` を読み込む
2. Read ツールで `past_topics.json` を読み込む
3. Read ツールで `templates/report-template.md` を読み込む
4. 今日の日付を確認する

### Step 2: テーマ選定 — テックトレンド

config.toml の `[tracks.tech]` に従い:

1. **ソース巡回**: WebSearch で以下を順に検索
   - "Hacker News top stories today" → トップ10記事のタイトルと概要を把握
   - "GitHub trending repositories this week" → 注目リポジトリを把握
   - "TechCrunch AI latest" → 最新のAI関連ニュースを把握
   - "arXiv cs.AI cs.CL latest papers" → 最新論文のトレンドを把握

2. **候補リストアップ**: 上記から5つのテーマ候補を挙げる。各候補について1行の概要を記述。

3. **スコアリング**: config.toml の scoring_criteria に従い各候補を採点（1-5点 × 重み）
   - 新規性 (30%): past_topics.json の過去テーマと比較
   - 変化の兆し (25%): 単なる発表ではなく、業界に変化を起こしそうか
   - 開発可能性 (25%): Python/Swift/TypeScriptで何か作れそうか
   - ウィスパートレンド度 (20%): まだ日本語圏であまり報じられていないか

4. **最高スコアのテーマを選定**。スコアリング結果は後のレポートには含めないが、判断根拠として保持する。

### Step 3: テーマ選定 — パーソナル関心

config.toml の `[tracks.personal]` に従い:

1. **ソース巡回**: WebSearch で以下を検索
   - "embodied cognition latest research 2026"
   - "mindfulness neuroscience new findings"
   - "Buddhist meditation technology intersection"
   - "body-mind connection latest studies"
   必要に応じて WebFetch で Semantic Scholar, Lion's Roar, Tricycle の記事を確認

2. **候補リストアップ**: 5つの候補。

3. **スコアリング**: Step 2と同じ基準 + 「テック×身体性の交差点」ボーナス (20%)

4. **最高スコアのテーマを選定**。

### Step 4: リサーチプロンプト動的生成

選定した各テーマについて、以下のプロセスでリサーチの深さを確保する:

1. **深掘り質問の生成**: 「このテーマについて知るべき重要な問い」を5つ自分で列挙
   例:
   - このテーマの技術的な背景は何か？
   - 現在の主要プレイヤーは誰か？
   - 最近の転換点や新展開は何か？
   - 開発者にとっての実践的な意味は？
   - 今後6ヶ月の見通しは？

2. **これらの問いに基づいて次のStep 5の検索を計画する**

### Step 5: 多段階リサーチ実行

各テーマについて:

1. Step 4で生成した問いに基づき、WebSearch を10-20回実行
   - 各問いについて2-3回の異なるクエリで検索
   - 英語と日本語の両方で検索し、情報の偏りを防ぐ

2. 重要なページは WebFetch で全文取得
   - 一次情報源（公式ブログ、論文、発表資料）を優先
   - ニュースサイトの二次情報は補足として扱う

3. 情報の相互検証
   - 1つのソースだけに依存しない
   - 複数ソースで一致する情報を事実として採用
   - 矛盾する情報がある場合はその旨を記述

### Step 6: レポート生成

templates/report-template.md のフォーマットに厳密に従い、2本のレポートを生成する。

各レポートの品質基準:
- **具体性**: 抽象的な記述を避け、具体的なツール名・数字・事例を含める
- **最新性**: 2026年の情報を優先。古い情報は「背景」セクションのみ
- **行動可能性**: 「開発アイデアへの示唆」セクションは具体的なアプリ/ツールのアイデアを含める
- **出典の質**: 信頼できるソースのURLを最低5件含める

### Step 7: 保存

1. Obsidian vault にレポートを保存:
   - パス: `{vault_path}/{output_dir}/{date}_{track}_{slug}.md`
   - slug: テーマ名の英語ケバブケース（例: "mcp-server-ecosystem"）
   - Write ツールを使用

2. past_topics.json を更新:
   - Read で現在の内容を読み込み
   - 新しいエントリ2件を追加
   - Write で書き戻し

### Step 8: 完了報告

最後に、以下の形式で完了を報告:

```
## Daily Research Complete

- Date: {date}
- Report 1: {tech_topic} → {filename}
- Report 2: {personal_topic} → {filename}
- Total searches: {search_count}
- Total sources cited: {source_count}
```
```

#### 2-2. `prompts/task-prompt.md`（`claude -p` の引数）

**What**: `claude -p` に渡す実行指示。短く明確にする。
**Why**: システムプロンプト（research-protocol.md）に詳細はあるので、ここでは「何をすべきか」の指示だけ。

```markdown
今日のデイリーリサーチを実行してください。

1. config.toml を読み込む
2. past_topics.json で過去テーマを確認する
3. テックトレンドとパーソナル関心の2テーマを選定する
4. 各テーマについて多段階リサーチを実行する
5. 3000字のレポートを2本生成し、Obsidian vault に保存する
6. past_topics.json を更新する

research-protocol.md に記載されたプロトコルに厳密に従ってください。
```

---

### Phase 3: シェルスクリプト

#### 3-1. `scripts/daily-research.sh`

**What**: launchdから呼ばれるラッパースクリプト。環境サニタイズ + 認証チェック + Claude Code実行。
**Why**: launchd環境ではPATH等が最小限のため、明示的に環境を設定する必要がある。また、`ANTHROPIC_API_KEY` が設定されていると従量課金になるため確実に除去する。

```bash
#!/bin/bash
set -euo pipefail

# === 環境サニタイズ ===
# APIキーが設定されていると従量課金になるため確実に除去
unset ANTHROPIC_API_KEY

# launchd環境はPATHが最小限。ユーザー環境を読み込む
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
# nodenv / nvm 等がある場合はここで読み込む
[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc" 2>/dev/null || true

# === 変数 ===
DATE=$(date +%Y-%m-%d)
TIME=$(date +%H:%M:%S)
PROJECT_DIR="$HOME/MyAI_Lab/daily-research"
LOG_DIR="$PROJECT_DIR/logs"
LOG_FILE="$LOG_DIR/$DATE.log"

mkdir -p "$LOG_DIR"

log() {
  echo "[$DATE $TIME] $1" >> "$LOG_FILE"
}

log "=== Starting daily research ==="

# === 認証チェック ===
if ! command -v claude &> /dev/null; then
  log "ERROR: claude command not found in PATH"
  osascript -e 'display notification "claude コマンドが見つかりません" with title "Daily Research Error"'
  exit 1
fi

# Claude OAuth認証状態チェック（claude --version が通るか）
if ! claude --version >> "$LOG_FILE" 2>&1; then
  log "ERROR: Claude authentication may have expired"
  osascript -e 'display notification "Claude認証の更新が必要です。claude を起動してください。" with title "Daily Research Auth Error"'
  exit 1
fi

# === 実行 ===
cd "$PROJECT_DIR"

TASK_PROMPT=$(cat prompts/task-prompt.md)

log "Executing claude -p with sonnet model..."

claude -p "$TASK_PROMPT" \
  --append-system-prompt-file prompts/research-protocol.md \
  --allowedTools "WebSearch,WebFetch,Read,Write,Glob,Grep" \
  --dangerously-skip-permissions \
  --max-turns 40 \
  --model sonnet \
  --output-format json \
  --no-session-persistence \
  >> "$LOG_FILE" 2>&1

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  log "=== Completed successfully ==="
  osascript -e 'display notification "今朝のリサーチレポートが完成しました" with title "Daily Research"'
else
  log "=== Failed with exit code $EXIT_CODE ==="
  osascript -e 'display notification "リサーチ実行に失敗しました。ログを確認してください。" with title "Daily Research Error"'
fi

exit $EXIT_CODE
```

#### 3-2. `scripts/check-auth.sh`

**What**: OAuth認証状態を確認するスクリプト。手動でも cron でも実行可能。
**Why**: OAuth トークンは約4日で期限切れ。事前に検知して通知する。

```bash
#!/bin/bash
# Claude Code OAuth認証状態チェック

if ! command -v claude &> /dev/null; then
  echo "ERROR: claude not found"
  osascript -e 'display notification "claude コマンドが見つかりません" with title "Auth Check"'
  exit 1
fi

# claude --version が正常に返ることで認証状態を間接確認
if claude --version > /dev/null 2>&1; then
  echo "OK: Claude authentication is valid"
  exit 0
else
  echo "WARN: Claude authentication may need refresh"
  osascript -e 'display notification "Claude認証の更新が必要です。ターミナルで claude を起動してください。" with title "Daily Research Auth Warning"'
  exit 1
fi
```

---

### Phase 4: launchd 設定

#### 4-1. `com.shimomoto.daily-research.plist`

**What**: macOS launchd のジョブ定義。毎朝 AM 5:00 に実行。
**Why**: launchd は macOS のネイティブスケジューラ。スリープ復帰時にも実行される（`StartCalendarInterval` の特性）。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.shimomoto.daily-research</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/shimomoto_tatsuya/MyAI_Lab/daily-research/scripts/daily-research.sh</string>
  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>5</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>/Users/shimomoto_tatsuya/MyAI_Lab/daily-research/logs/launchd-stdout.log</string>

  <key>StandardErrorPath</key>
  <string>/Users/shimomoto_tatsuya/MyAI_Lab/daily-research/logs/launchd-stderr.log</string>

  <key>WorkingDirectory</key>
  <string>/Users/shimomoto_tatsuya/MyAI_Lab/daily-research</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key>
    <string>/Users/shimomoto_tatsuya</string>
  </dict>
</dict>
</plist>
```

**登録コマンド**:
```bash
# シンボリックリンクを作成（plist ファイルの管理をプロジェクト内に保つ）
ln -sf ~/MyAI_Lab/daily-research/com.shimomoto.daily-research.plist \
       ~/Library/LaunchAgents/com.shimomoto.daily-research.plist

# ロード
launchctl load ~/Library/LaunchAgents/com.shimomoto.daily-research.plist

# 手動テスト実行
launchctl start com.shimomoto.daily-research

# アンロード（停止時）
launchctl unload ~/Library/LaunchAgents/com.shimomoto.daily-research.plist
```

#### 4-2. 認証チェック用 plist（オプション）

**What**: 毎日 AM 4:50 に認証状態を確認。失敗時に macOS 通知。
**Why**: 本番実行の10分前にチェックし、認証切れに気づけるようにする。

```xml
<!-- com.shimomoto.daily-research-auth-check.plist -->
<key>StartCalendarInterval</key>
<dict>
  <key>Hour</key>
  <integer>4</integer>
  <key>Minute</key>
  <integer>50</integer>
</dict>
```

---

### Phase 5: テスト・検証

#### 5-1. 手動テスト（Phase 2 完了後すぐ）

```bash
cd ~/MyAI_Lab/daily-research

# Step 1: プロンプトの妥当性を対話モードで確認
# （まず対話モードで research-protocol.md の指示に従えるか確認）
claude

# Step 2: 非対話モードでの完全実行テスト
TASK_PROMPT=$(cat prompts/task-prompt.md)
claude -p "$TASK_PROMPT" \
  --append-system-prompt-file prompts/research-protocol.md \
  --allowedTools "WebSearch,WebFetch,Read,Write,Glob,Grep" \
  --dangerously-skip-permissions \
  --max-turns 40 \
  --model sonnet \
  --output-format json
```

**確認項目**:
- [ ] Obsidian vault に 2 ファイルが生成された
- [ ] frontmatter（date, category, tags, topic, sources）が正しい
- [ ] 各レポートが 2500〜3500 字の範囲
- [ ] 出典が最低 5 件、URLが有効
- [ ] 「開発アイデアへの示唆」セクションが具体的
- [ ] past_topics.json が更新された
- [ ] 日本語で出力されている
- [ ] Obsidian で開いた際にフォーマットが崩れない

#### 5-2. シェルスクリプトテスト（Phase 3 完了後）

```bash
# 実行権限付与
chmod +x scripts/daily-research.sh
chmod +x scripts/check-auth.sh

# 認証チェック
./scripts/check-auth.sh

# フルスクリプト実行
./scripts/daily-research.sh

# ログ確認
cat logs/$(date +%Y-%m-%d).log
```

#### 5-3. launchd テスト（Phase 4 完了後）

```bash
# 手動トリガー
launchctl start com.shimomoto.daily-research

# ログ確認
tail -f logs/launchd-stdout.log
cat logs/$(date +%Y-%m-%d).log

# 翌朝: Obsidian を開いてレポートを確認
```

#### 5-4. 1週間運用テスト

**確認項目**:
- [ ] テーマの重複がない（past_topics.json の効果）
- [ ] レポート品質が安定している（品質のばらつきが小さい）
- [ ] 認証エラーが発生していない
- [ ] ログにエラーがない
- [ ] `--max-turns 40` で完走できている（足りない場合は増やす）
- [ ] Obsidian の daily-research フォルダに毎日2ファイルずつ増えている

---

### Phase 6: 品質チューニング（運用開始後）

#### 6-1. プロンプトの反復改善

**What**: 生成されたレポートを読み、プロンプトを改善するサイクル。
**Why**: 初版プロンプトで完璧な品質は出ない。実際のレポートを見て調整する。

改善ポイントの例:
- テーマが表面的 → スコアリング基準の「ウィスパートレンド度」の重みを上げる
- 出典が弱い → 「一次情報源を優先」の指示を強化
- 「開発アイデア」が抽象的 → 「具体的なアプリ名・機能を含めること」を追加
- レポートが長すぎ/短すぎ → 文字数制約を調整

#### 6-2. 月次メタレビュー（オプション）

月1回、以下を手動 or 自動で実行:
- past_topics.json の過去30日のテーマ傾向を分析
- 偏り（特定分野に集中していないか）を検出
- 必要に応じて config.toml のソースや重みを調整

---

## 実装ステップまとめ

| # | Phase | 作業内容 | 成果物 | 依存 |
|---|-------|---------|--------|------|
| 1 | 設定ファイル | config.toml, past_topics.json, report-template.md 作成 | 3ファイル | なし |
| 2 | プロンプト設計 | research-protocol.md, task-prompt.md 作成 | 2ファイル | Phase 1 |
| 3 | 手動テスト | 対話モード → 非対話モードで実行テスト | テスト結果 | Phase 2 |
| 4 | プロンプト調整 | テスト結果に基づきプロンプト修正（2-3回反復） | 改善版プロンプト | Phase 3 |
| 5 | シェルスクリプト | daily-research.sh, check-auth.sh 作成 | 2ファイル | Phase 4 |
| 6 | launchd設定 | plist 作成、登録 | 1ファイル + 登録 | Phase 5 |
| 7 | 自動実行テスト | 翌朝の自動実行を検証 | 確認結果 | Phase 6 |
| 8 | 1週間運用テスト | 毎朝レポートを確認、品質チューニング | 安定運用 | Phase 7 |

---

## リスクと対策

| リスク | 影響 | 対策 |
|--------|------|------|
| OAuth トークン期限切れ | 自動実行が失敗 | check-auth.sh で事前通知 + 週2回手動で `claude` 起動 |
| `--max-turns 40` で足りない | リサーチが中途半端に終了 | ログで確認、必要に応じて50-60に増加 |
| WebSearch の品質が低い | テーマが表面的、情報が古い | プロンプトで検索クエリの質を指示 + WebFetch で一次情報を補強 |
| コンテキスト圧縮による品質劣化 | 後半のレポートが前半より薄い | `--no-session-persistence` でセッション毎にリセット |
| Obsidian vault のパス変更 | 保存先が見つからない | config.toml で管理、変更は1箇所だけ |
| API レート制限 | WebSearch が失敗 | max-turns に余裕を持たせ、リトライの機会を確保 |

---

## 将来の拡張（今は実装しない）

- **MCP サーバー追加**: Hacker News API、arXiv API 等の専用 MCP を追加し、WebSearch 依存を減らす
- **品質スコアリング自動化**: 生成レポートを別のClaude呼び出しで評価し、品質が低い場合はリトライ
- **テーマ推薦フィードバック**: Obsidian 上で「このテーマは良かった/悪かった」をマークし、フィードバックループを作る
- **Plan B へのアップグレード**: WebSearch品質に不満がある場合、Gemini CLI を情報収集フェーズに追加
