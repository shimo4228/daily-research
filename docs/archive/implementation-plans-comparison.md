# daily-research 実装プラン — 2つのアーキテクチャ比較

作成日: 2026-02-14

## Context

SESSION_HANDOFF.mdに基づき、毎朝2本のリサーチレポートをObsidianに届けるシステムを構築する。
2つのDeep Researchレポート（Obsidian Vault内）がそれぞれ異なるアーキテクチャを提案している。
ここでは両方を**daily-researchプロジェクトの要件に合わせた具体的な実装プラン**として並べ、比較判断できるようにする。

### 共通の前提

- Maxプラン加入済み → Claude Code利用時の追加API費用ゼロ
- 毎朝 AM 5:00 に launchd で自動実行
- レポート2本: テックトレンド + パーソナル関心（身体性認知科学・仏教）
- 出力先: Obsidian Vault (`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault/daily-research/`)
- 運用: 構築後は読むだけ。手作業ゼロ（OAuth更新を除く）

### 元になった提案

- **提案A**: 「高度AIサブスクリプション群を活用した自律型ディープリサーチ環境の構築とゼロコスト・オーケストレーション戦略」
- **提案B**: 「Claude MAX・Gemini Pro・ChatGPT Plusを駆使した高品質リサーチ自動化のベストプラクティス」

---

## Plan A: Claude Code 単体オーケストレーター方式

### What
Claude Code の非対話モード（`claude -p`）をカスタムSkillで起動し、テーマ選定からレポート出力まで**単一プロセス内で自律完結**させる。

### Why
- **最もシンプル**: 外部CLIやAPIへの依存がない。Claude Code + Maxプランだけで完結
- **エージェントの自律判断**: 途中で「この情報が足りない」と判断したら追加検索できる
- **Skill/Hookのエコシステム**: 既存の `~/.claude/skills/` 資産を活用可能
- **コスト**: 完全にゼロ（Maxプラン定額内）

### Alternatives considered
- OpenAI Deep Research API（$80-200/月 → コスト不可）
- Perplexity API（追加コスト発生）
- Python + 各社API直接呼び出し（Maxプラン恩恵を受けられない）

### アーキテクチャ

```
launchd (AM 5:00)
    ↓
daily-research.sh（環境サニタイズ）
    ↓
claude -p "/daily-research" \
  --allowedTools "WebSearch,WebFetch,Read,Write,Bash,mcp__*" \
  --permission-mode bypassPermissions \
  --max-turns 30 \
  --output-format json
    ↓
Claude Code が Skill に従い自律実行：
  [1] テーマ選定（WebSearch でソース巡回 + past_topics.json 重複チェック）
  [2] プロンプト動的生成（テーマに最適化されたリサーチ問い）
  [3] 多段階リサーチ（WebSearch × 10-20回 + WebFetch で一次情報取得）
  [4] レポート構成・執筆（3000字 × 2本）
  [5] Obsidian vault に Write ツールで直接保存
```

### プロジェクト構成

```
daily-research/
├── PLAN.md
├── config.toml                    # テーマソース、出力先等の設定
├── past_topics.json               # テーマ履歴（重複防止）
├── prompts/
│   ├── tech_research.md           # テックトラック用リサーチプロンプトテンプレート
│   └── personal_research.md       # パーソナルトラック用テンプレート
├── scripts/
│   ├── daily-research.sh          # launchdから呼ばれるラッパー
│   └── check-auth.sh             # OAuth認証状態チェック
├── com.shimomoto.daily-research.plist  # launchd設定
└── logs/                          # 実行ログ
```

加えて、グローバルSkill:
```
~/.claude/skills/daily-research/SKILL.md   # リサーチプロトコル定義
```

### 主要ファイルの設計

#### `~/.claude/skills/daily-research/SKILL.md`

```markdown
---
name: daily-research
description: 毎朝自動実行。2本のリサーチレポートを生成しObsidianに保存する。
allowed-tools: WebSearch, WebFetch, Read, Write, Bash
---

# 自律型ディープリサーチ・プロトコル

## あなたの役割
主席リサーチャーとして、以下のプロトコルに厳密に従って調査を実行する。

## 実行手順

### Step 1: 設定読み込み
- `config.toml` からテーマソース、出力先を読み込む
- `past_topics.json` から過去30日のテーマ履歴を読み込む

### Step 2: テーマ選定（テックトレンド）
- WebSearch で以下を巡回: Hacker News トップ記事, arXiv cs.AI/cs.CL 最新, TechCrunch最新
- 候補を5つリストアップ
- 以下の基準でスコアリング（各1-5点）:
  - 新規性: 過去テーマと重複しないか
  - 変化の兆し: 静的知識ではなく動いている領域か
  - 開発可能性: Python/Swift/TypeScriptで何か作れそうか
  - ウィスパートレンド度: まだ多くの人が気づいていない変化か
- 最高スコアのテーマを選定

### Step 3: テーマ選定（パーソナル関心）
- WebSearch で以下を巡回: Semantic Scholar (embodied cognition, mindfulness), arXiv q-bio.NC
- Lion's Roar, Tricycle, Mindful Magazine の最新記事をWebFetchで確認
- Step 2と同じ基準 + 「テック×身体性の交差点」ボーナスでスコアリング

### Step 4: リサーチプロンプト動的生成
- 選定テーマごとに、以下を含む詳細なリサーチ問いを生成:
  - 背景と文脈
  - 現在の最新状況
  - 注目プレイヤー/論文
  - 開発者としてのアクションアイテム
  - 出典を必ず含める指示

### Step 5: 多段階リサーチ実行
- 各テーマについて WebSearch を10-20回実行
- 重要なページは WebFetch で全文取得
- 情報の相互検証（複数ソースの一致を確認）

### Step 6: レポート生成（各3000字）
- 指定フォーマット（frontmatter + 統一セクション構成）で執筆
- 「開発アイデアへの示唆」セクションを必ず含める
- 出典URLを末尾にリスト

### Step 7: 保存
- Write ツールで Obsidian vault に直接保存
- past_topics.json を更新

## 出力フォーマット
（PLAN.mdで定義済みのfrontmatter + セクション構成に従う）

## 制約
- 日本語で出力すること
- 各レポートは3000字前後
- 出典は最低5件
- past_topics.json に記録済みのテーマは避ける
```

#### `scripts/daily-research.sh`

```bash
#!/bin/bash
set -euo pipefail

# === 環境サニタイズ ===
# APIキーが設定されていると従量課金になるため確実に除去
unset ANTHROPIC_API_KEY

# ログイン環境の読み込み（Node.js等のパス解決）
source ~/.zshrc 2>/dev/null || true

# === 変数 ===
DATE=$(date +%Y-%m-%d)
LOG_DIR="$HOME/Library/Logs/daily-research"
LOG_FILE="$LOG_DIR/$DATE.log"
PROJECT_DIR="$HOME/MyAI_Lab/daily-research"

mkdir -p "$LOG_DIR"

echo "[$DATE $(date +%H:%M:%S)] Starting daily research..." >> "$LOG_FILE"

# === 認証チェック ===
if ! claude --version > /dev/null 2>&1; then
  echo "ERROR: claude command not found" >> "$LOG_FILE"
  exit 1
fi

# === 実行 ===
cd "$PROJECT_DIR"

claude -p "/daily-research" \
  --allowedTools "WebSearch,WebFetch,Read,Write" \
  --permission-mode bypassPermissions \
  --max-turns 30 \
  --model sonnet \
  --output-format json \
  >> "$LOG_FILE" 2>&1

echo "[$DATE $(date +%H:%M:%S)] Completed." >> "$LOG_FILE"
```

### コンテキスト管理（Hook）

`.claude/settings.json` に追加:

```json
{
  "hooks": {
    "UserPromptSubmit": [{
      "command": "cat ~/MyAI_Lab/daily-research/prompts/context-reminder.txt",
      "description": "リサーチプロトコルの再注入（忘却防止）"
    }]
  }
}
```

### OAuth認証問題への対応

- **頻度**: ~4日ごとにトークン更新が必要
- **対策1**: 週2回、手動で `claude` を対話起動してトークンリフレッシュ
- **対策2**: `otelHeadersHelper` にトークン再取得スクリプトを設定（提案Aの手法）
- **対策3**: check-auth.sh で認証状態を事前チェックし、失敗時は通知（macOS通知）

### 実装ステップ

| Phase | 作業 | 所要時間目安 |
|-------|------|-------------|
| 1 | config.toml, past_topics.json 作成 | 30分 |
| 2 | SKILL.md 作成・テスト（手動で `/daily-research` 実行） | 2-3時間 |
| 3 | daily-research.sh 作成 | 30分 |
| 4 | launchd plist 作成・登録 | 30分 |
| 5 | 翌朝の自動実行を検証 | 翌日確認 |
| 6 | Hook設定（コンテキスト再注入） | 1時間 |
| 7 | 1週間の運用テスト・品質チューニング | 1週間 |

---

## Plan B: マルチCLIパイプライン方式

### What
Python オーケストレータスクリプトが **Gemini CLI で情報収集** → **Claude Code で分析・執筆** のパイプラインを順次実行する。各フェーズで最適なモデルを使い分ける。

### Why
- **各モデルの強みを活かせる**: Gemini の Google検索連携（最新情報取得に最強）+ Claude の分析・執筆力
- **コンテキスト枯渇リスクが低い**: フェーズごとにプロセスが分離されるため
- **デバッグしやすい**: パイプラインの各段階で中間出力を確認可能
- **拡張性**: 将来 ChatGPT CLI や他のツールを追加しやすい

### Alternatives considered
- Claude Code 単体（Plan A — 検索深度がGeminiに劣る可能性）
- OpenAI Deep Research API（コスト不可）
- 全工程を Gemini CLI に任せる（執筆・構造化がClaudeに劣る）

### アーキテクチャ

```
launchd (AM 5:00)
    ↓
daily-research.sh（環境サニタイズ）
    ↓
python orchestrator.py
    ↓
[Phase 1: テーマ選定] ← Claude Code (claude -p)
  │  config.toml + past_topics.json を読み込み
  │  WebSearch でソース巡回、テーマ候補リストアップ
  │  スコアリングして2テーマ決定
  │  → themes.json に出力
  ↓
[Phase 2: 情報収集] ← Gemini CLI (gemini -p) × 2並列
  │  テーマ1: テックトレンドの最新情報をGoogle検索で網羅的に収集
  │  テーマ2: パーソナル関心の学術論文・記事を収集
  │  → raw_data_tech.md, raw_data_personal.md に出力
  ↓
[Phase 3: 分析・レポート生成] ← Claude Code (claude -p) × 2順次
  │  raw_data + テーマ情報を入力として
  │  3000字のレポートを生成（frontmatter付き）
  │  → reports/YYYY-MM-DD_tech_xxx.md, reports/YYYY-MM-DD_personal_xxx.md
  ↓
[Phase 4: Obsidian出力]
  │  生成されたレポートをObsidian vaultにコピー
  │  past_topics.json を更新
  ↓
完了
```

### プロジェクト構成

```
daily-research/
├── pyproject.toml                 # uv管理
├── PLAN.md
├── config.toml
├── past_topics.json
├── src/
│   ├── __init__.py
│   ├── orchestrator.py            # メインパイプライン
│   ├── config.py                  # config.toml + 環境変数読み込み
│   ├── theme_selector.py          # Claude Code呼び出しでテーマ選定
│   ├── info_collector.py          # Gemini CLI呼び出しで情報収集
│   ├── report_generator.py        # Claude Code呼び出しでレポート生成
│   ├── obsidian_writer.py         # Obsidian vault への書き出し
│   └── topic_history.py           # past_topics.json 管理
├── prompts/
│   ├── theme_selection.md         # テーマ選定用プロンプト
│   ├── info_collection_tech.md    # テック情報収集用プロンプト
│   ├── info_collection_personal.md
│   ├── report_generation.md       # レポート生成用プロンプト
│   └── context_profile.md         # ユーザープロファイル（スキル、関心）
├── scripts/
│   ├── daily-research.sh          # launchdラッパー
│   └── check-auth.sh             # 認証チェック（Claude + Gemini両方）
├── tmp/                           # 中間ファイル（themes.json, raw_data等）
├── logs/
├── tests/
│   └── ...
└── com.shimomoto.daily-research.plist
```

### 主要ファイルの設計

#### `src/orchestrator.py`

```python
"""Daily Research Pipeline Orchestrator"""
import subprocess
import json
from datetime import datetime
from pathlib import Path
from dataclasses import dataclass

from .config import load_config
from .theme_selector import select_themes
from .info_collector import collect_info
from .report_generator import generate_report
from .obsidian_writer import write_to_obsidian
from .topic_history import TopicHistory


def run_pipeline() -> None:
    config = load_config()
    history = TopicHistory(config.past_topics_path)
    today = datetime.now().strftime("%Y-%m-%d")

    # Phase 1: テーマ選定（Claude Code）
    themes = select_themes(config, history)

    # Phase 2: 情報収集（Gemini CLI — 2テーマ並列実行可能）
    raw_data = {}
    for theme in themes:
        raw_data[theme.track] = collect_info(theme, config)

    # Phase 3: レポート生成（Claude Code — 順次実行）
    reports = []
    for theme in themes:
        report = generate_report(theme, raw_data[theme.track], config)
        reports.append(report)

    # Phase 4: Obsidian出力
    for report in reports:
        write_to_obsidian(report, config)

    # Phase 5: 履歴更新
    for theme in themes:
        history.add(today, theme)

    print(f"[{today}] Generated {len(reports)} reports.")


if __name__ == "__main__":
    run_pipeline()
```

#### `src/theme_selector.py`（Claude Code呼び出し）

```python
def select_themes(config, history) -> list[Theme]:
    prompt = build_theme_selection_prompt(config, history)

    result = subprocess.run(
        [
            "claude", "-p", prompt,
            "--allowedTools", "WebSearch,WebFetch",
            "--permission-mode", "bypassPermissions",
            "--max-turns", "15",
            "--model", "sonnet",
            "--output-format", "json",
        ],
        capture_output=True, text=True, timeout=600,
    )

    return parse_themes(result.stdout)
```

#### `src/info_collector.py`（Gemini CLI呼び出し）

```python
def collect_info(theme: Theme, config: Config) -> str:
    prompt = build_collection_prompt(theme)

    result = subprocess.run(
        [
            "gemini", "-p", prompt,
            # Gemini CLI のオプション（要確認）
        ],
        capture_output=True, text=True, timeout=600,
    )

    return result.stdout
```

#### `src/report_generator.py`（Claude Code呼び出し）

```python
def generate_report(theme: Theme, raw_data: str, config: Config) -> Report:
    prompt = build_report_prompt(theme, raw_data, config)

    result = subprocess.run(
        [
            "claude", "-p", prompt,
            "--allowedTools", "WebSearch,WebFetch",
            "--permission-mode", "bypassPermissions",
            "--max-turns", "10",
            "--model", "sonnet",
            "--output-format", "json",
        ],
        capture_output=True, text=True, timeout=600,
    )

    return parse_report(result.stdout)
```

### Gemini CLI統合の詳細

- **インストール**: `npm install -g @google/gemini-cli`
- **認証**: Google アカウントで OAuth（`gemini auth login`）
- **無料枠**: 個人アカウントで1000リクエスト/日
- **非対話モード**: `gemini -p "プロンプト"` でヘッドレス実行
- **利点**: Google検索と直接連携するため、最新のWeb情報取得精度が高い

### 認証管理

| サービス | 認証方式 | 更新頻度 |
|----------|---------|---------|
| Claude Code | OAuth（`/login`） | ~4日ごと |
| Gemini CLI | Google OAuth | 要調査（おそらく長い） |

→ 2つのOAuth管理が必要。weekly cron でヘルスチェック + 通知を実装。

### 実装ステップ

| Phase | 作業 | 所要時間目安 |
|-------|------|-------------|
| 1 | `uv init`, pyproject.toml, config.toml | 30分 |
| 2 | Gemini CLI インストール・認証テスト | 1時間 |
| 3 | config.py, topic_history.py | 1時間 |
| 4 | theme_selector.py（Claude Code呼び出し） | 2時間 |
| 5 | info_collector.py（Gemini CLI呼び出し）| 2時間 |
| 6 | report_generator.py（Claude Code呼び出し）| 2時間 |
| 7 | obsidian_writer.py | 30分 |
| 8 | orchestrator.py 統合テスト | 2時間 |
| 9 | daily-research.sh + launchd設定 | 1時間 |
| 10 | 1週間の運用テスト | 1週間 |

---

## 比較表

| 観点 | Plan A: Claude Code単体 | Plan B: マルチCLIパイプライン |
|------|------------------------|------------------------------|
| **複雑さ** | 低（Skill 1ファイル + シェル1本） | 中（Python 6ファイル + CLI 2つ） |
| **検索品質** | WebSearch依存（中） | Gemini Google検索連携（高） |
| **分析・執筆品質** | Claude直接（高） | Claude直接（高） |
| **コンテキスト管理** | 単一セッション（圧縮リスクあり） | フェーズ分離（リスク低） |
| **追加コスト** | ゼロ（Maxプランのみ） | ゼロ（Max + Gemini Pro定額内） |
| **認証管理** | Claude OAuth 1つ | Claude OAuth + Google OAuth 2つ |
| **デバッグ性** | 低（ブラックボックス的） | 高（中間ファイルで確認可能） |
| **拡張性** | MCP追加で拡張可能 | CLI/API追加で拡張容易 |
| **実装工数** | 小（数時間） | 中（1-2日） |
| **障害時の影響** | 全体停止 | フェーズ単位で部分的に対処可能 |

---

## SESSION_HANDOFFの未解決課題への対応（両プラン共通）

### 1. テーマ選定アルゴリズム

**スコアリング基準（5段階）:**

| 基準 | 説明 | 重み |
|------|------|------|
| 新規性 | past_topics.json に類似テーマがないか | 30% |
| 変化の兆し | 静的知識ではなく動いている領域か | 25% |
| 開発可能性 | Python/Swift/TSで何か作れそうか | 25% |
| ウィスパートレンド度 | まだ多くの人が気づいていない変化か | 20% |

→ これをプロンプト内の指示として埋め込み、Claude自身にスコアリングさせる。

### 2. プロンプト動的生成

OpenAI推奨の3段階を応用:
1. **候補テーマの深掘り質問生成**: 「このテーマについて知りたいこと」をClaude自身に列挙させる
2. **構造化リサーチプロンプト作成**: 列挙した問いを統合し、多角的なリサーチ指示に変換
3. **リサーチ実行**: 生成したプロンプトに従って多段階WebSearchを実行

### 3. 長期品質維持

- `past_topics.json` にテーマ + 日付 + カテゴリを蓄積
- 30日以上前の類似テーマは再訪可（十分な変化がありうる）
- 月1回「メタレビュー」: 過去30日のテーマ傾向を分析し、偏りを検出

---

## 検証方法

### 初回テスト
1. 手動で Skill / orchestrator.py を実行
2. Obsidian Vault にレポート2本が生成されることを確認
3. フォーマット（frontmatter, タグ, セクション構成）の正しさを確認
4. 出典リンクが有効か確認

### 自動実行テスト
1. launchd に登録
2. 翌朝 Obsidian を開いてレポートを確認
3. ログファイルでエラーがないことを確認

### 1週間運用テスト
- テーマの重複がないか
- レポート品質が安定しているか
- コンテキスト圧縮による品質劣化がないか（Plan Aの場合）
- 認証エラーが発生していないか

---

## 調査で判明した技術的事実（参考）

### Deep Research APIコスト（不採用の理由）
- OpenAI o3-deep-research: $1.3〜$3.4/回 → 月$78〜$204
- 個人の日次リサーチとしてはコスト不可

### Claude Code CLI非対話モードの仕様
- `claude -p "プロンプト"` で非対話実行
- `--allowedTools`: ツール許可リスト指定
- `--permission-mode bypassPermissions`: 権限確認スキップ
- `--output-format json`: 構造化出力
- `--max-turns N`: ターン数上限
- `--model sonnet|opus|haiku`: モデル指定

### OAuth認証の制約
- トークン有効期限: ~4日
- `ANTHROPIC_API_KEY` が設定されていると従量課金に切り替わる
- バックグラウンド実行時のトークン更新に既知バグあり

### テーマソースのAPI
- Hacker News: 公式REST API、認証不要、レート制限なし
- arXiv: 公式REST API、認証不要、3秒間隔推奨
- Semantic Scholar: 公式API、認証不要（推奨）、214M論文
- TechCrunch: RSS (`feedparser`)、認証不要
- Lion's Roar / Tricycle / Mindful: RSSフィード確認済み

### Maxプラン利用量
- Max 5x: 225メッセージ/5時間、~200-400 Sonnet時間/週
- 毎日2本のリサーチ（各数分）は全く問題ない使用量
