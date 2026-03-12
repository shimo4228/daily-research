Language: [English](README.md) | 日本語

# daily-research

[Claude Code](https://docs.anthropic.com/en/docs/claude-code) の非対話モードと macOS `launchd` を使った、自動デイリーリサーチレポートシステム。

**Python 不要。シェルスクリプト + プロンプトファイルだけ。**

毎朝 5:00 に Claude が自律的にウェブを検索し、トレンドトピックを選定、多段階のディープリサーチを行い、レポートを [Obsidian](https://obsidian.md) Vault に直接書き出します。

## 仕組み

```
launchd (AM 5:00)
  └─ daily-research.sh
       ├── MCP ヘルスチェック (Haiku)
       │     ├── OK → Mem0 有効
       │     └── Fail → Mem0 なしで続行
       │
       ├── Pass 1: Opus (テーマ選定)
       │     ├── config.toml を読み込み     # リサーチ対象の定義
       │     ├── past_topics.json を読み込み # 重複回避
       │     ├── WebSearch                   # 最新トレンド調査
       │     └── スコアリング & 2テーマ選定
       │
       ├── Pass 2: Sonnet (リサーチ & 執筆)
       │     ├── Mem0 search-memories   # 過去の知見を想起 (利用可能な場合)
       │     ├── WebSearch x 20-30      # 多段階リサーチ
       │     ├── WebFetch (一次ソース)
       │     ├── レポート 2本を執筆     # → Obsidian vault
       │     └── Mem0 add-memory        # 主要な知見を保存 (利用可能な場合)
       │
       └── Eval: Opus (品質スコアリング、非致命的)
             ├── 6次元 x 2レポート
             └── scores.jsonl に追記
```

**2パスアーキテクチャ**: Opus がテーマ選定（深い推論）、Sonnet がリサーチと執筆（速度 + コスト効率）を担当。Pass 1 が失敗した場合は Sonnet がフォールバックとして全てを処理します。

重要なポイント: Claude Code の `-p` フラグにより、完全自律型のリサーチエージェントとして動作します。API の配管もPythonもオーケストレーションフレームワークも不要。知性はプロンプトに宿ります。

## 特徴

- **2パスモデルルーティング** -- テーマ選定に Opus、リサーチに Sonnet（両方の長所を活用）
- **設定可能なリサーチトラック** -- `config.toml` でトピック、ソース、スコアリング基準を定義
- **トピック重複排除** -- `past_topics.json` により30日以内に同じテーマを扱うことを防止
- **多段階ディープリサーチ** -- 単なる要約ではなく、リサーチクエスチョンを生成し、20〜30回検索し、ソースを相互検証
- **重み付きトピックスコアリング** -- 新規性、モメンタム、構築可能性、「ウィスパートレンド」スコア
- **Obsidian ネイティブ出力** -- YAML フロントマター付きレポート、Vault にそのまま配置可能
- **永続メモリ (Mem0)** -- オプションの MCP 統合により、過去のリサーチ知見を想起し、新しい知見をセッション間で保存
- **堅牢な実行** -- ロックファイル、ログローテーション、認証チェック、macOS 通知、自動フォールバック
- **自動品質評価** -- LLM-as-Judge が各レポートを6次元（30点満点）で採点

## 前提条件

| 要件 | 備考 |
|------|------|
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | `brew install claude` または npm 経由 |
| [Claude Max プラン](https://claude.ai) | 非対話モードをコスト0で利用するため |
| macOS | スケジューリングに `launchd` を使用（Linux の場合は `cron` や `systemd` に適宜変更） |
| Obsidian (任意) | Markdown 対応ツールなら何でも可 |

## クイックスタート

```bash
# 1. クローン
git clone https://github.com/shimo4228/daily-research.git
cd daily-research

# 2. 設定
cp config.example.toml config.toml
# config.toml を編集: vault_path を設定し、トラックをカスタマイズ

# 3. スクリプトに実行権限を付与
chmod +x scripts/daily-research.sh scripts/eval-run.sh scripts/check-auth.sh

# 4. Claude の認証を確認
./scripts/check-auth.sh

# 5. テスト実行 (手動)
./scripts/daily-research.sh

# 6. launchd でスケジュール (任意)
cp com.example.daily-research.plist com.daily-research.plist
# 編集: YOUR_USERNAME を macOS のユーザー名に置換
ln -sf "$(pwd)/com.daily-research.plist" ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.daily-research.plist
```

## プロジェクト構成

```
daily-research/
├── config.example.toml         # リサーチトラック、スコアリング、出力設定
├── prompts/
│   ├── theme-selection-prompt.md  # Pass 1: テーマ選定 (Opus)
│   ├── task-prompt.md             # Pass 2: リサーチ指示 (Sonnet)
│   └── research-protocol.md      # Pass 2: リサーチプロトコル (システムプロンプト)
├── templates/
│   └── report-template.md      # YAML フロントマター付きレポートフォーマット
├── scripts/
│   ├── daily-research.sh       # メインエントリポイント (launchd から呼び出し)
│   ├── eval-run.sh             # LLM-as-Judge 評価 (実行後)
│   └── check-auth.sh           # OAuth トークンヘルスチェック
├── evals/
│   ├── prompts/                # 評価ルーブリック (6次元 + システムプロンプト)
│   ├── scores.jsonl            # スコアログ (追記のみ、gitignore 対象)
│   └── scores.example.jsonl    # スキーマ参照用
├── com.example.daily-research.plist  # launchd スケジュールテンプレート
├── tests/
│   ├── test-daily-research.bats     # ユニットテスト
│   ├── test-e2e-mock.bats          # E2E モックテスト
│   ├── test-eval.bats              # 評価フレームワークテスト
│   └── test-log-summary.bats       # log_summary パーサーテスト
└── docs/
    ├── RUNBOOK.md / RUNBOOK.ja.md   # 運用ガイド
    ├── CONTRIB.md / CONTRIB.ja.md   # 開発ガイド
    └── plans/                       # 今後の拡張計画
```

## 評価フレームワーク

各実行成功後に、自動 LLM-as-Judge 評価が生成された全レポートを採点します。これは非致命的なフックとして実行され、評価の失敗がメインパイプラインをブロックすることはありません。

各レポートは Opus により6つの独立した次元（各1〜5点、合計30点満点）で採点されます:

| 次元 | 評価内容 |
|------|---------|
| 事実的根拠 (Factual Grounding) | ソースの質と主張の検証 |
| 分析の深さ (Depth of Analysis) | 表面的な要約を超えた分析 |
| 一貫性 (Coherence) | 論理的な流れと構造 |
| 具体性 (Specificity) | 抽象的な記述ではなく具体的な事例 |
| 新規性 (Novelty) | 一般的な知識を超えた新鮮な洞察 |
| 実行可能性 (Actionability) | 実用的な開発アイデア |

スコアは `evals/scores.jsonl` に追記されます。`pipeline_version` フィールドにより、パイプライン変更時のビフォー・アフター比較が可能です。詳細は [CONTRIB.ja.md](docs/CONTRIB.ja.md) を参照してください。

## カスタマイズ

### リサーチトラックの追加

`config.toml` を編集して新しいトラックを追加:

```toml
[tracks.finance]
name = "Finance & Markets"
focus = "Fintech, DeFi, and market trends"
sources = [
  "Bloomberg Technology",
  "TechCrunch Fintech",
]
scoring_criteria = [
  { name = "Novelty", weight = 30, desc = "Not covered recently" },
  { name = "Momentum", weight = 30, desc = "Actively evolving" },
  { name = "Actionability", weight = 40, desc = "Can act on this insight" },
]
```

### 言語

プロンプトファイル (`prompts/`) とレポートテンプレートは日本語で書かれています。デフォルトではレポートは日本語で生成されます。出力言語を変更するには:

1. `prompts/research-protocol.md` の10行目にある言語制約を編集:
   ```
   - 日本語で全て出力すること  →  - Output everything in English
   ```
2. `prompts/research-protocol.md` と `templates/report-template.md` を希望の言語に翻訳。

### リサーチ深度の調整

`prompts/research-protocol.md` を編集して以下を調整:
- トピックあたりの検索クエリ数
- ソース検証の要件
- レポートの構成と長さ

### スケジュールの変更

plist の `StartCalendarInterval` を編集:

```xml
<key>Hour</key>
<integer>7</integer>  <!-- 7 AM に変更 -->
```

再読み込み: `launchctl unload ... && launchctl load ...`

## 主要な設計判断

| 判断 | 理由 |
|------|------|
| 2パス (Opus + Sonnet) | テーマ選定で Opus が優位（ブラインド評価で +28%）; リサーチ・執筆は Sonnet の方が高速かつ低コスト |
| Pass 1 失敗時の Sonnet フォールバック | 耐障害性: Opus がタイムアウトや失敗した場合、Sonnet が全てを処理 |
| `--append-system-prompt-file`（`--system-prompt-file` ではなく） | Claude Code のデフォルト機能を維持しつつリサーチ指示を追加 |
| `--allowedTools`（`--dangerously-skip-permissions` ではなく） | 最小権限: Pass 1 は読み取り専用、Pass 2 で書き込みを追加 |
| タイムアウト制御に `--max-turns` | プロセス外タイムアウト (gtimeout) はシグナルで claude を kill し、データ損失を引き起こす |
| シェルスクリプトのみ | Claude Code CLI 以外の依存ゼロ; 理解と変更が容易 |
| TOML 設定 | 人間が読みやすく、トラック・基準のネスト構造をサポート |
| LLM-as-Judge（非致命的） | 本番をブロックせずに自動品質フィードバック; 6つの独立次元で単一スコアのバイアスを低減 |
| `< /dev/null` stdin リダイレクト | MCP の stdio 通信がターミナルの stdin と競合するのを防止（MCP ハングの根本原因） |
| MCP ヘルスチェック（非致命的） | Pass 1 前に Mem0 MCP を検証; 失敗時は Mem0 ツールを除外して続行 |
| Pass 1 に `stream-json` | コスト・パフォーマンス監視のためツール使用回数を結果とともにキャプチャ |

## 注意事項

- **Claude Code プラグインがハングを引き起こす** -- グローバルにインストールされた Claude Code プラグインがあると、`claude -p` の呼び出しごとに MCP サーバーが初期化され、数分のオーバーヘッドやハングの原因になります。プロジェクトルートに `.claude/settings.json` を作成して無効化してください:
  ```json
  {
    "enabledPlugins": {
      "plugin-name@marketplace": false
    }
  }
  ```
  インストール済みプラグインを全て列挙し `false` に設定します。インストール済みプラグインは `claude plugin list` で確認できます。現時点では一括無効化オプションはありません（[tracking issue](https://github.com/anthropics/claude-code/issues/20873)）。
- **OAuth トークンは約4日で期限切れ** -- 定期的に `claude` を対話的に実行してリフレッシュしてください
- **`ANTHROPIC_API_KEY` は未設定であること** -- 設定されていると Max プランではなくトークン単位の課金になります。スクリプトは `unset ANTHROPIC_API_KEY` で対処しています
- **launchd + シェルプロファイル** -- `launchd` は `.zshrc` を読み込みません。全ての PATH エントリはスクリプトと plist に明示的に記述する必要があります
- **`--max-turns`** -- Pass 1 は15ターン（テーマ選定）、Pass 2 は40ターン（リサーチ）。これらはガイドラインであり厳密な上限ではありません
- **Claude Code 内から実行しないこと** -- `claude -p` は別の Claude Code セッション内からネストして実行できません

## ドキュメント

- [RUNBOOK.md](docs/RUNBOOK.md) / [RUNBOOK.ja.md](docs/RUNBOOK.ja.md) -- 運用: モニタリング、トラブルシューティング、よくある問題
- [CONTRIB.md](docs/CONTRIB.md) / [CONTRIB.ja.md](docs/CONTRIB.ja.md) -- 開発: テスト、CLI フラグ、環境変数

## ライセンス

[MIT](LICENSE)
