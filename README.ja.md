Language: [English](README.md) | 日本語

# daily-research

自分の研究リポジトリのためのリサーチフィードバックエンジン。[Claude Code](https://docs.anthropic.com/en/docs/claude-code) の非対話モードと macOS `launchd` で動きます。

**Python 不要。シェルスクリプト + プロンプトファイルだけ。**

毎朝 5:00 に Claude が、あなたが管理する各研究リポジトリの concept graph を読み込み、外部研究でまだ補強されていない concept を特定し、そのギャップを埋める最新研究をリサーチして、レポートを [Obsidian](https://obsidian.md) Vault に直接書き出します。各レポートの末尾には「この repo への寄与」節が付くので、発見した内容を人間が手で元リポジトリに取り込めます。

これはもともと汎用トレンドリサーチツール（tech / personal / ai_dev トラック）でした。2026-05-27 に再設計しています。固定トピックドメインが構造的飽和を招き（1 つの concept クラスタが全トピックの 37% を占めた）、各トラックを 1 つの研究リポジトリにマッピングし、テーマをその repo の concept coverage gap で駆動する方式に切り替えました。詳しい背景は [ADR-0001](docs/adr/0001-research-repo-feedback-engine.md) を参照してください。

## 仕組み

```
launchd (AM 5:00)
  └─ daily-research.sh
       ├── 認証チェック (check-auth.sh)
       ├── 各 repo の graph を同期 → .repo-graphs/<track>.jsonld
       ├── coverage-report.sh        # トラックごとの未補強 concept
       │
       ├── Pass 1: Opus (テーマ選定)
       │     ├── config.toml を読み込み      # track → repo マッピング
       │     ├── repo graph + coverage report を読み込み
       │     ├── WebSearch                    # 未補強 concept を補強する研究
       │     └── スコアリング & トラックごと 1 テーマ選定
       │
       ├── Pass 2: Sonnet (リサーチ & 執筆)
       │     ├── WebSearch x 10-20         # 多段階リサーチ
       │     ├── WebFetch (一次ソース)
       │     ├── レポートを執筆            # → Obsidian vault
       │     ├── 「この repo への寄与」節を追記
       │     ├── past_topics.json を更新   # トピック履歴
       │     └── graph.jsonld を更新       # 補強した concept を記録
       │
       └── (Eval: LLM-as-Judge — 現在運用停止中、後述)
```

**2パスアーキテクチャ**: Opus がテーマ選定（repo graph 群への深い推論）、Sonnet がリサーチと執筆（高速・低コスト）を担当します。Pass 1 が失敗した場合は Sonnet がフォールバックとして全てを処理します。

**concept coverage が検索を駆動します。** トレンドを追うのではなく、「repo の graph にある全 concept `@id` から `graph.jsonld` で補強済みの concept を引いた差分」を計算し、Pass 1 にそのギャップを埋める外部研究を優先させます。トレンドは移ろいますが、未補強 concept は具体的で反復可能なターゲットです。

重要なポイント: Claude Code の `-p` フラグにより、完全自律型のリサーチエージェントとして動作します。API の配管も Python もオーケストレーションフレームワークも不要。知性はプロンプトに宿ります。

## 特徴

- **2パスモデルルーティング** -- テーマ選定に Opus、リサーチと執筆に Sonnet
- **repo マッピング型リサーチトラック** -- 各トラックを 1 つの研究リポジトリにマッピング; 関心領域は固定キーワードドメインではなく、その repo の `graph.jsonld` から導出
- **coverage 駆動のテーマ選定** -- `coverage-report.sh` が repo ごとの未補強・薄い concept を列挙し Pass 1 に注入
- **concept cluster graph** -- `graph.jsonld`、schema.org JSON-LD の永続メモリ（250 記事、7 broad + 57 sub クラスタ）; Pass 2 が実行ごとに増分更新
- **トピック履歴** -- `past_topics.json` は選定されたテーマの履歴を蓄積（Pass 2 が更新; Pass 1 での重複排除役は `coverage-report.sh` に移行）
- **多段階ディープリサーチ** -- 単なる要約ではなく、リサーチクエスチョンを生成し、10〜20 回検索し、ソースを相互検証
- **repo フィードバックループ** -- 各レポート末尾の「この repo への寄与」節で、補強した concept 名と repo の拡張方法を提案
- **Obsidian ネイティブ出力** -- YAML フロントマター付きレポート、Vault にそのまま配置可能
- **運用上のセーフティネット** -- ロックファイル、ログローテーション、認証チェック、macOS 通知、Sonnet 自動フォールバック
- **品質評価（停止中）** -- LLM-as-Judge がレポートを 6 次元で採点するフレームワーク; コスト都合で現在オフ、コードは保持

## 前提条件

| 要件 | 備考 |
|------|------|
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | `brew install claude` または npm 経由 |
| [Claude Max プラン](https://claude.ai) | 非対話モードをコスト0で利用するため |
| macOS | スケジューリングに `launchd` を使用（Linux の場合は `cron` や `systemd` に適宜変更） |
| Obsidian (任意) | Markdown 対応ツールなら何でも可 |
| 研究リポジトリ | `graph.jsonld` concept graph を持つ repo を 1 つ以上（[graph-schema.md](docs/graph-schema.md) 参照） |

## Claude Code skill としてインストール

```bash
git clone https://github.com/shimo4228/daily-research.git \
  ~/.claude/skills/daily-research
```

このリポジトリはルートに [`SKILL.md`](SKILL.md) マニフェストを備えているため、Claude Code が skill として認識します。clone 後は `/daily-research` で手動実行するか、下記の「クイックスタート」の launchd 手順で自動実行を設定してください。Linux の場合は launchd 部分を cron か systemd に置き換えます。

## クイックスタート

```bash
# 1. クローン
git clone https://github.com/shimo4228/daily-research.git daily-research
cd daily-research

# 2. 設定
cp config.example.toml config.toml
# config.toml を編集: vault_path を設定し、各トラックを研究 repo にマッピング

# 3. スクリプトに実行権限を付与
chmod +x scripts/daily-research.sh scripts/coverage-report.sh \
         scripts/check-auth.sh scripts/bootstrap-graph.sh

# 4. Claude の認証を確認
./scripts/check-auth.sh

# 5. (任意) 既存のトピック履歴から concept graph を bootstrap
#    past_topics.json をクラスタに分類したい場合に 1 度だけ実行
./scripts/bootstrap-graph.sh

# 6. テスト実行 (手動; Claude Code セッション内ではなく別ターミナルで)
./scripts/daily-research.sh

# 7. launchd でスケジュール (任意)
cp com.example.daily-research.plist com.daily-research.plist
# 編集: YOUR_USERNAME を macOS のユーザー名に置換
ln -sf "$(pwd)/com.daily-research.plist" ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.daily-research.plist
```

## プロジェクト構成

```
daily-research/
├── scripts/
│   ├── daily-research.sh       # メインエントリポイント (repo graph 同期 → Opus テーマ → Sonnet リサーチ)
│   ├── bootstrap-graph.sh      # graph.jsonld 初回 bootstrap (Opus clustering、ワンショット)
│   ├── coverage-report.sh      # 未補強 concept レポート、Pass 1 へ注入
│   └── check-auth.sh           # OAuth トークンヘルスチェック
├── prompts/
│   ├── theme-selection-prompt.md  # Pass 1: repo graph 駆動のテーマ選定 (Opus)
│   ├── task-prompt.md             # Pass 2: リサーチ・執筆指示 (Sonnet)
│   └── research-protocol.md       # Pass 2: リサーチプロトコル (品質の中核、システムプロンプト)
├── templates/
│   └── report-template.md      # YAML フロントマター付きレポートフォーマット
├── graph.jsonld                # 永続メモリ: concept cluster graph + 補強履歴 (Git 管理)
├── .repo-graphs/               # 各トラックの repo graph 同期コピー (起動時生成、gitignore)
├── config.example.toml         # track → repo マッピング、スコアリング、出力設定 (config.toml は gitignore)
├── past_topics.example.json    # トピック履歴のスキーマ参照用
├── evals/                      # LLM-as-Judge 評価 (運用停止中; コード保持)
│   └── scores.example.jsonl    # スコアログのスキーマ参照用
├── tests/                      # bats テスト (daily-research / e2e-mock / eval / log-summary)
├── docs/
│   ├── RUNBOOK.md / RUNBOOK.ja.md   # 運用ガイド
│   ├── CONTRIB.md / CONTRIB.ja.md   # 開発ガイド
│   ├── graph-schema.md              # graph.jsonld スキーマ仕様
│   ├── adr/                         # アーキテクチャ決定記録 (ADR)
│   ├── plans/                       # 今後の拡張計画
│   └── progress/                    # ポストモーテム・評価レポート
└── com.example.daily-research.plist  # launchd スケジュールテンプレート
```

## Concept Coverage エンジン

各トラックは 1 つの研究リポジトリを指します。起動時に repo の `graph.jsonld` を `.repo-graphs/<track>.jsonld` へコピーします（read-only; 元 repo は決して編集しません）。続いて `coverage-report.sh` が次の 2 つの集合を差分します。

- repo の graph に宣言された全 concept `@id`、と
- このプロジェクトの `graph.jsonld` で既に `reinforces` に記録された concept。

その差分が **未補強 concept** の集合です。Pass 1 はこのレポートを受け取り、それらの concept を優先的に補強する外部研究を選びます。Pass 2 がレポートを書くとき、補強した concept を `reinforces` フィールド経由で `graph.jsonld` に書き戻すので、次回の実行ではギャップが小さくなります。

`graph.jsonld` 自体は schema.org JSON-LD モデル（レポートを表す `Article` ノード、クラスタを表す `Thing` ノード）に従います。完全なスキーマ — ノード型、クラスタ命名、整合性ルール — は [graph-schema.md](docs/graph-schema.md) に記載しています。

## 品質評価（停止中）

このリポジトリには、生成された各レポートを 6 つの独立した次元（各 1〜5 点、合計 30 点満点）で採点する LLM-as-Judge フレームワークが含まれます: 事実的根拠、分析の深さ、一貫性、具体性、新規性、実行可能性。スコアは `evals/scores.jsonl` に追記され、`pipeline_version` フィールドでビフォー・アフター比較ができます。

**この評価は現在運用停止中です。** コスト対効果が低かったためです。`daily-research.sh` の呼び出しはコメントアウトされており、`evals/` ディレクトリと `scripts/eval-run.sh` はコメント解除で復旧できるよう保持しています。詳細は [CONTRIB.ja.md](docs/CONTRIB.ja.md) を参照してください。

## カスタマイズ

### トラックを研究 repo にマッピング

`config.toml` を編集して各トラックをリポジトリに向けます:

```toml
[tracks.repo_a]
name = "Research Repo A Contribution"
focus = "Discover external research that reinforces and extends the concept system of research repo A"
target_repo = "/path/to/your/research-repo-a"
target_graph = ".repo-graphs/repo_a.jsonld"   # 同期後の cwd 相対パス
target_doi = "10.xxxx/zenodo.xxxxxxxx"          # 任意; repo に DOI があれば
sources = [
  "Semantic Scholar (your repo's domain keywords)",
  "arXiv (relevant categories for the repo)",
]
scoring_criteria = [
  { name = "Concept reinforcement", weight = 35, desc = "Reinforces an uncovered / thinly-supported concept" },
  { name = "Research recency", weight = 25, desc = "Latest research or development" },
  { name = "Repo frontier fit", weight = 40, desc = "Serves the repo's next direction" },
]
```

固定の `domains` はありません。関心領域は実行時に repo の graph から導出されます。フィードしたい repo ごとに 1 トラックを定義します。

### 言語

プロンプトファイル (`prompts/`) とレポートテンプレートは日本語で書かれています。デフォルトではレポートは日本語で生成されます。出力言語を変更するには:

1. `prompts/research-protocol.md` の言語制約を編集:
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
| 各トラック = 1 研究 repo（coverage-gap 駆動） | 固定トピックドメインが構造的飽和を招いた; repo graph にマッピングし未補強 concept を優先することでドメイン狭隘化を防ぐ（[ADR-0001](docs/adr/0001-research-repo-feedback-engine.md)） |
| 外部 MCP メモリではなくローカル JSON-LD graph | 旧 Mem0 MCP 統合は静かな失敗で 32 日間ゼロ稼働した; ローカル `graph.jsonld` は「ファイルが存在すれば動く」で失敗が顕在化する |
| repo は read-only 参照 | パイプラインは元 repo を決して編集しない; 寄与は人間が取り込む vault レポート経由で流れ、repo 間汚染を回避 |
| 2パス (Opus + Sonnet) | テーマ選定は Opus が優位; リサーチ・執筆は Sonnet の方が高速かつ低コスト |
| Pass 1 失敗時の Sonnet フォールバック | 耐障害性: Opus がタイムアウトや失敗した場合、Sonnet がテーマ選定も処理 |
| `--append-system-prompt-file`（`--system-prompt-file` ではなく） | Claude Code のデフォルト機能を維持しつつリサーチ指示を追加 |
| `--allowedTools`（`--dangerously-skip-permissions` ではなく） | 最小権限: Pass 1 は読み取り専用、Pass 2 で書き込みを追加 |
| タイムアウト制御に `--max-turns` | プロセス外タイムアウト (gtimeout) はシグナルで claude を kill し、データ損失を引き起こす |
| シェルスクリプトのみ | Claude Code CLI 以外の依存ゼロ; 理解と変更が容易 |
| TOML 設定 | 人間が読みやすく、トラック・基準のネスト構造をサポート |
| `< /dev/null` stdin リダイレクト | MCP の stdio 通信がターミナルの stdin と競合するのを防止（MCP ハングの根本原因） |

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
- **Claude Code 内から実行しないこと** -- `claude -p` は別の Claude Code セッション内からネストして実行できません; 別ターミナルで実行してください

## ドキュメント

- [RUNBOOK.md](docs/RUNBOOK.md) / [RUNBOOK.ja.md](docs/RUNBOOK.ja.md) -- 運用: モニタリング、トラブルシューティング、よくある問題
- [CONTRIB.md](docs/CONTRIB.md) / [CONTRIB.ja.md](docs/CONTRIB.ja.md) -- 開発: テスト、CLI フラグ、環境変数
- [graph-schema.md](docs/graph-schema.md) -- `graph.jsonld` スキーマ: ノード型、クラスタ命名、整合性ルール
- [ADR-0001](docs/adr/0001-research-repo-feedback-engine.md) -- なぜ各トラックを研究リポジトリにマッピングするか

## ライセンス

[MIT](LICENSE)
