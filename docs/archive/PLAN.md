# daily-research — 実装プラン

## Context

次の開発プロジェクトのアイデアを発見するため、毎朝2本の自動リサーチレポートを
Obsidianに届ける仕組みを構築する。テックトレンドだけでなく、個人の関心領域
（身体性認知科学・仏教）との交差点からもアイデアを探る。

## 決定済みの要件

| 項目 | 決定 |
|------|------|
| 頻度 | 毎日2本 |
| 分量 | 各~3000字（計30分で読める） |
| レポート1 | テックトレンド（AI自律選定） |
| レポート2 | パーソナル関心：身体性認知科学・仏教（AI自律選定） |
| 共通セクション | 「開発アイデアへの示唆」を両方に含む（交差点を探る） |
| テーマ選定 | AIが自律的に決定 |
| 実行タイミング | 毎朝 AM 5:00（起床前に完成） |
| 閲覧方法 | Obsidian（既存vault、iCloud同期） |
| 運用 | 構築後は読むだけ。手作業ゼロ |
| テーマソース | HN/GitHub Trending/TechCrunch/arxiv + config.tomlで変更可能 |
| プロジェクト名 | daily-research |

## リサーチエンジン

**OpenAI Deep Research API**（推奨）

- モデル: `o3-deep-research-2025-06-26`
- 公式API。ToSリスクなし
- APIキー所持済み
- Deep Research品質（GPT Researcherより大幅に高品質）
- config.tomlでエンジンを差し替え可能にしておく（Perplexity API等への切替に備える）

## 全体フロー

```
毎朝 AM 5:00 (launchd)
    ↓
[1. テーマ選定]
    │  レポート1: テックトレンドから1テーマ選定
    │  レポート2: 身体性認知科学・仏教から1テーマ選定
    │  過去レポートとの重複チェック
    ↓
[2. リサーチ実行]  ← OpenAI Deep Research API
    │  2テーマを順次実行（各2-4分）
    ↓
[3. レポート整形]  ← Claude Haiku API
    │  統一フォーマットに整形
    │  「開発アイデアへの示唆」セクション生成
    │  Obsidian互換のfrontmatter + タグ
    ↓
[4. Obsidian vaultに保存]
    │  vault/daily-research/YYYY-MM-DD_tech_テーマ名.md
    │  vault/daily-research/YYYY-MM-DD_personal_テーマ名.md
    ↓
ユーザーが朝Obsidianを開いて読む（iPhone/iPadでも可）
```

## レポートフォーマット

```markdown
---
date: 2026-02-14
category: tech  # or "personal"
tags: [AI, エージェント, MCP, 開発ツール]
topic: "MCPサーバーエコシステムの急成長"
sources: 12
---

# MCPサーバーエコシステムの急成長

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

## プロジェクト構成

```
MyAI_Lab/daily-research/
├── pyproject.toml              # uv管理
├── .env                        # APIキー（git管理外）
├── config.toml                 # 設定
│     ├── vault_path            # Obsidian vaultパス
│     ├── research_engine       # "openai-deep-research" (差し替え可能)
│     ├── schedule_time         # "05:00"
│     ├── tracks                # レポートトラック定義
│     │     ├── tech            # テックトレンド
│     │     │     ├── sources   # [HN, GitHub Trending, TechCrunch, arxiv]
│     │     │     └── focus     # "開発者向けテクノロジートレンド"
│     │     └── personal        # パーソナル関心
│     │           ├── domains   # ["身体性認知科学", "仏教", "瞑想"]
│     │           └── focus     # "身体性認知科学・仏教の最新研究や実践"
│     └── report                # レポート設定
│           ├── max_chars       # 3000
│           └── language        # "ja"
├── src/
│   ├── __init__.py
│   ├── main.py                 # エントリポイント
│   ├── config.py               # 設定読み込み
│   ├── topic_selector.py       # テーマ選定
│   ├── researcher.py           # OpenAI Deep Research API呼び出し
│   ├── report_formatter.py     # レポート整形（Claude Haiku）
│   └── obsidian_writer.py      # Obsidian vaultへの書き出し
├── past_topics.json            # 過去テーマ履歴
├── tests/
│   └── ...
└── com.shimomoto.daily-research.plist  # launchd設定
```

## Obsidian vault

**パス:**
```
/Users/shimomoto_tatsuya/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault
```

**レポート保存先:**
```
Obsidian Vault/
├── daily-research/
│   ├── 2026-02-14_tech_mcp-server-ecosystem.md
│   ├── 2026-02-14_personal_embodied-cognition-meditation.md
│   ├── 2026-02-15_tech_...md
│   └── ...
```

プラグイン不要。フォルダにMDを書くだけで連携完了。
iCloud同期でiPhone/iPadからも読める。

## config.toml の例

```toml
[general]
vault_path = "/Users/shimomoto_tatsuya/Library/Mobile Documents/iCloud~md~obsidian/Documents/Obsidian Vault"
output_dir = "daily-research"
language = "ja"

[engine]
provider = "openai-deep-research"  # 将来 "perplexity" 等に差し替え可能
model = "o3-deep-research-2025-06-26"

[formatter]
provider = "anthropic"
model = "claude-haiku-4-5-20251001"
max_chars = 3000

[tracks.tech]
name = "テックトレンド"
focus = "開発者向けテクノロジートレンド。新しいツール、フレームワーク、AI、OSS"
sources = ["hackernews", "github_trending", "techcrunch", "arxiv_cs"]

[tracks.personal]
name = "パーソナル関心"
focus = "身体性認知科学・仏教の最新研究や実践"
domains = ["身体性認知科学", "Embodied Cognition", "仏教", "瞑想", "マインドフルネス"]
```

## 必要なAPIキー

- [x] OpenAI API（所持済み）— Deep Research エンジン
- [x] Anthropic API（所持済み）— レポート整形

## 実装ステップ

### Phase 1: プロジェクトセットアップ
1. `MyAI_Lab/daily-research/` を `uv init` で作成
2. 依存追加: `openai`, `anthropic`, `tomli`, `httpx` 等
3. `config.toml` を作成
4. `.env` にAPIキーを配置
5. `.gitignore` に `.env` を追加

### Phase 2: コア機能の実装
1. `config.py` — config.toml + .env の読み込み
2. `topic_selector.py` — テーマ選定（Web検索 + 過去履歴チェック）
3. `researcher.py` — OpenAI Deep Research API呼び出し
4. `report_formatter.py` — Claude Haikuでレポートフォーマット整形
5. `obsidian_writer.py` — frontmatter付きMDファイルをvaultに書き出し
6. `main.py` — 上記を順に実行

### Phase 3: テスト・検証
1. 手動で `main.py` を実行してレポートが生成されることを確認
2. Obsidianで開いてフォーマット・タグ・グラフビューを確認
3. 2本目（パーソナル関心）の品質も確認

### Phase 4: スケジューリング
1. launchd plist を作成（毎朝 AM 5:00 実行）
2. ログ出力設定（~/Library/Logs/daily-research/）
3. 翌朝の自動実行を確認

## 検証方法

1. `cd MyAI_Lab/daily-research && .venv/bin/python -m src.main` で手動実行
2. Obsidian Vault/daily-research/ にファイルが2つ生成されていることを確認
3. Obsidianで開き、frontmatter・タグ・フォーマットが正しいことを確認
4. `launchctl load` でスケジューラーを登録し、翌朝の自動実行を確認
5. ログファイルでエラーがないことを確認
