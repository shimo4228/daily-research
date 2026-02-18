# 永続メモリ統合 実装計画

作成日: 2026-02-18

## 概要

### What

Mem0 Cloud MCP サーバーを agent-team に統合し、過去調査テーマの知識ベース・有効だったリサーチ手法・ユーザーの関心パターンを蓄積・再利用する永続メモリ層を構築する。

### Why

- **テーマ選定の質向上**: 現行の past_topics.json はキーワード一致による重複排除のみ。意味的類似度で「既知領域」を判断できるようになる
- **リサーチ戦略の学習**: 毎回ゼロから検索戦略を組み立てている。過去に有効だったクエリパターン・ソースを再利用できる
- **関心パターンの自動追跡**: config.toml に手動記述している関心領域を、実績ベースで自動更新できる
- **最小変更で統合可能**: MCP サーバーは外部プロセスとして動く。プロジェクトのシェルスクリプトに Python を持ち込まない

### Alternatives Considered

| 候補 | 判定 | 理由 |
|------|------|------|
| **Mem0 Cloud MCP** (npx) | **採用** | 3用途すべてカバー。npx 一発。無料枠で十分 |
| mcp-local-rag (npx) | 不採用 | ファイル取り込み型で構造化メモリに弱い。テーマ検索には強いが手法蓄積・関心追跡に対応できない |
| memvid v2 CLI (cargo) | 不採用 | v2 用 MCP サーバーが未整備。`claude -p` からの制御が困難 |
| basic-memory (uv) | 不採用 | ベクトル検索なし（全文検索のみ）。Obsidian 互換は魅力だが意味的類似度が弱い |
| claude-mem | 不採用 | `claude -p` 非対話モードで動作しない（プラグインフック依存） |
| Mem0 OpenMemory (Docker) | 不採用 | Docker 3コンテナは過剰。launchd 環境での安定性に懸念 |

### トレードオフ

- **クラウド依存**: Mem0 Cloud にデータが送信される。ただし記憶するのはテーマ名・検索戦略・関心パターンであり機密性は低い
- **無料枠の上限**: 10,000 メモリ / 1,000 検索/月。日次2レポート × 30日で約10回/日の検索なら月300回程度で余裕あり
- **外部サービス障害時**: past_topics.json をフォールバックとして残すため、Mem0 ダウン時も最低限の重複排除は維持

---

## 前提条件

- Node.js がインストール済み（`npx` が使える）
- Mem0 Cloud のアカウント作成済み（[app.mem0.ai](https://app.mem0.ai)）
- API キー取得済み（Starter プラン: 無料）

---

## メモリカテゴリ設計

Mem0 のメモリはユーザー単位で管理される。`metadata` フィールドでカテゴリを区別する。

### カテゴリ一覧

| カテゴリ | 用途 | 記録タイミング | 記録内容の例 |
|---------|------|-------------|-------------|
| `topic_history` | 過去テーマの意味的検索 | レポート生成後 | `"AIエージェントのメモリインフラについて調査。memvid, Mem0, Letta を比較。コンテキストエンジニアリングへのパラダイムシフトが主題"` |
| `research_method` | 有効だったリサーチ手法 | レポート生成後 | `"GitHub Trending + 'site:arxiv.org' 検索の組み合わせが、学術×実装の交差点を見つけるのに有効だった"` |
| `source_quality` | ソースの有効性評価 | レポート生成後 | `"VentureBeat の予測記事は概観に有用だが一次情報に乏しい。arxiv + GitHub が最も信頼性が高い"` |
| `user_interest` | ユーザーの関心パターン | テーマ選定時 | `"エージェントアーキテクチャ、MCP エコシステム、身体性×テクノロジーの交差点に継続的関心"` |

### メモリの構造（Mem0 mcp__mem0__add-memory 呼び出し例）

```
mcp__mem0__add-memory({
  messages: [{ role: "user", content: "テーマ「AIエージェントのメモリインフラ」を調査した。..." }],
  user_id: "daily-research",
  metadata: {
    category: "topic_history",
    date: "2026-02-18",
    track: "tech",
    slug: "ai-agent-memory-infrastructure"
  }
})
```

---

## 実装フェーズ

### Phase 0: PoC（動作検証）

**目的**: Mem0 MCP が `claude -p` で実際に動くか検証する

**手順**:

1. Mem0 Cloud アカウント作成・API キー取得
2. `.mcp.json` を作成し Mem0 MCP サーバーを登録
   ```json
   {
     "mcpServers": {
       "mem0": {
         "command": "npx",
         "args": ["-y", "@mem0/mcp-server"],
         "env": {
           "MEM0_API_KEY": "${MEM0_API_KEY}"
         }
       }
     }
   }
   ```
3. 環境変数 `MEM0_API_KEY` の設定方法を決定
   - 対話セッション: `.envrc` or `export` で設定
   - launchd 実行: plist の `EnvironmentVariables` に追加
4. 手動で `claude -p` を実行し、以下を検証
   - `mcp__mem0__add-memory` でメモリを追加できるか
   - `mcp__mem0__search-memories` で意味的検索が機能するか
   - `--allowedTools` に `mcp__mem0__add-memory,mcp__mem0__search-memories` を指定して自動承認されるか
5. `.mcp.json` を `.gitignore` に追加（API キー参照を含むため）

**成果物**:
- `.mcp.json`（テンプレートを `.mcp.example.json` として Git 管理）
- PoC 結果の記録（動作確認項目のチェックリスト）

**判定基準**: add → search の往復が `claude -p` で動けば Phase 1 へ進む

**所要見込み**: 1〜2時間

---

### Phase 1: 過去レポートの取り込み

**目的**: 既存の daily-research レポートを Mem0 に取り込み、知識ベースの初期データを構築する

**手順**:

1. 取り込みスクリプト `scripts/seed-memory.sh` を作成
   - Obsidian vault の `daily-research/` 内の既存 `.md` ファイルを列挙
   - 各ファイルから YAML frontmatter（date, category, tags, topic）+ 本文の要約を抽出
   - `claude -p` を使って各レポートの要約を生成し、Mem0 に `topic_history` カテゴリで登録
2. メモリカテゴリの初期データ投入
   - `topic_history`: 既存レポートのテーマ要約（全件）
   - `research_method`: 初期値は手動で2〜3件登録（過去の経験から）
   - `source_quality`: 初期値は手動で2〜3件登録
   - `user_interest`: config.toml の tracks 設定から初期値を生成
3. 取り込み結果の検証
   - `mcp__mem0__search-memories` で既知テーマを検索し、関連レポートがヒットするか確認
   - 意味的に近いテーマ同士が近傍に来るか確認（例: 「LLM のコンテキスト管理」と「エージェントメモリ」）

**成果物**:
- `scripts/seed-memory.sh`
- `.mcp.example.json`（Git 管理用テンプレート）

**所要見込み**: 半日

---

### Phase 2: agent-team への統合

**目的**: team-orchestrator がメモリを参照してテーマ選定・リサーチ戦略を改善する

**変更対象ファイル**:

| ファイル | 変更内容 |
|---------|---------|
| `scripts/agent-team-research.sh` | `--allowedTools` に Mem0 ツールを追加 |
| `prompts/team-protocol.md` | メモリ参照・更新ステップを追加 |
| `.claude/agents/team-orchestrator.md` | メモリ活用の指示を追加 |
| `.claude/agents/team-researcher.md` | （変更なし — メモリはオーケストレーターが管理） |
| `.claude/agents/team-writer.md` | （変更なし） |

**2-1. `--allowedTools` の拡張**

```bash
# scripts/agent-team-research.sh（変更箇所）
--allowedTools "Task,WebSearch,WebFetch,Read,Write,Glob,Grep,mcp__mem0__add-memory,mcp__mem0__search-memories"
```

**2-2. team-protocol.md の変更**

既存の Step 1（config.toml / past_topics.json の Read）の後に、メモリ参照ステップを挿入する。

```
Step 1.5（新規）: Mem0 メモリの参照
  - mcp__mem0__search-memories で過去30日のテーマ傾向を取得
  - mcp__mem0__search-memories で過去に有効だったリサーチ手法を取得
  - 取得した情報を以降のテーマ選定・リサーチ戦略に活用
```

既存の Step 6（past_topics.json 更新）の後に、メモリ更新ステップを追加する。

```
Step 6.5（新規）: Mem0 メモリの更新
  - 今回のテーマ情報を topic_history として追加
  - 今回有効だったリサーチ手法を research_method として追加
  - ソースの有効性評価を source_quality として追加
```

**2-3. team-orchestrator.md の変更**

役割定義に以下を追加:

```markdown
## メモリ活用（Mem0）

あなたはセッションを跨いだ永続メモリにアクセスできる。

### テーマ選定時
- `mcp__mem0__search-memories` で過去のテーマ履歴を確認し、意味的に重複するテーマを避ける
- past_topics.json のキーワードチェックに加え、Mem0 の意味的検索で「似たテーマを別角度で扱った」ケースも検出する
- `mcp__mem0__search-memories` で過去に評価の高かったリサーチ手法を取得し、今回の戦略に活用する

### レポート生成後
- 今回のテーマ要約を `mcp__mem0__add-memory`（category: topic_history）で記録する
- 今回有効だった検索クエリ・ソースを `mcp__mem0__add-memory`（category: research_method, source_quality）で記録する

### 注意
- Mem0 が応答しない場合は past_topics.json のみで続行する（フォールバック）
- メモリ操作の失敗でパイプライン全体を止めない
```

**2-4. past_topics.json との役割分担**

| 機能 | past_topics.json | Mem0 |
|------|-----------------|------|
| キーワード重複排除 | ○（継続） | — |
| 意味的重複排除 | — | ○（新規） |
| リサーチ手法の蓄積 | — | ○（新規） |
| ソース評価の蓄積 | — | ○（新規） |
| フォールバック | ○（Mem0 障害時の保険） | — |

**所要見込み**: 半日〜1日

---

### Phase 3: 学習ループの実装

**目的**: 各実行の成果を自動的にメモリに蓄積し、次回実行の質を継続的に改善するフィードバック機構を構築する

**3-1. 実行後の自動記録**

team-orchestrator の最終ステップとして以下を追加:

```
Step 7（新規）: 学習メモリの記録

以下を Mem0 に記録する:

1. topic_history:
   - テーマ名、トラック、日付
   - テーマの要約（2〜3文）
   - スコアリング結果（どの基準で高スコアだったか）

2. research_method:
   - 今回使った検索クエリのうち、質の高い情報が得られたもの
   - 検索言語（日本語/英語）ごとの有効性
   - 「この組み合わせが有効だった」というパターン

3. source_quality:
   - 今回参照したソースの有効性評価
   - 「一次情報として信頼できた」「概観には良いが深さが足りない」等
```

**3-2. 次回実行時の活用フロー**

```
[実行開始]
  ↓
Step 1: config.toml / past_topics.json を Read
  ↓
Step 1.5: Mem0 mcp__mem0__search-memories
  ├── "最近のテーマ傾向" → テーマ選定の方向性に反映
  ├── "有効だったリサーチ手法" → 検索戦略に反映
  └── "ソース評価" → 優先的に参照するソースの選択に反映
  ↓
Step 2-3: テーマ選定（メモリ情報を加味したスコアリング）
  ↓
Step 4-5: リサーチ・執筆
  ↓
Step 6: past_topics.json 更新 + ファイル保存
  ↓
Step 7: 学習メモリの記録（mcp__mem0__add-memory × 3カテゴリ）
  ↓
[実行終了]
```

**3-3. メモリのメンテナンス**

- 90日超の `topic_history` は要約を圧縮して1件にまとめる（四半期サマリー）
- `research_method` と `source_quality` は件数が増えたら類似項目をマージ
- メンテナンスは手動で月1回程度実施（自動化は Phase 3 以降で検討）

**所要見込み**: 半日〜1日

---

## リスクと緩和策

| リスク | 影響度 | 発生確率 | 緩和策 |
|-------|--------|---------|--------|
| Mem0 Cloud の障害・メンテナンス | 中 | 低 | past_topics.json をフォールバックとして残す。メモリ操作失敗時はスキップして続行 |
| 無料枠（1,000検索/月）の超過 | 低 | 低 | 月300回程度の見込み。超過時は Pro プラン($249/月)への移行を検討、または mcp-local-rag への切り替え |
| API キーの漏洩 | 高 | 低 | `.mcp.json` を `.gitignore` に追加。launchd plist の `EnvironmentVariables` で注入 |
| メモリの肥大化・ノイズ増加 | 中 | 中 | カテゴリ別管理 + 90日アーカイブルール。Phase 3 で圧縮ロジックを実装 |
| `claude -p` + MCP の未知の非互換 | 中 | 中 | Phase 0 の PoC で早期検証。問題があれば代替案（mcp-local-rag）に切り替え |
| Mem0 Cloud の料金体系変更 | 低 | 低 | ローカル代替（OpenMemory Docker / mcp-local-rag）へのマイグレーションパスを Phase 2 完了時点で文書化 |

---

## 成功指標

| 指標 | 測定方法 | 目標 |
|------|---------|------|
| テーマの意味的重複回避率 | 過去30日のレポートと新テーマの意味的類似度スコア | 類似度 0.8 超のテーマが選ばれない |
| リサーチ手法の再利用率 | メモリから取得した手法が実際に使われた割合 | 50%以上（Phase 3 安定後） |
| レポート品質の維持 | 出典数・文字数・散文比率が既存水準を維持 | 既存版と同等以上 |
| パイプラインの安定性 | Mem0 統合後の実行成功率 | 95%以上（Mem0 障害込み） |

---

## スケジュール概要

```
Phase 0 (PoC)        ████░░░░░░░░░░░░  1-2時間
Phase 1 (取り込み)    ░░░░████████░░░░  半日
Phase 2 (統合)        ░░░░░░░░████████  半日〜1日
Phase 3 (学習ループ)  ░░░░░░░░░░░░████  半日〜1日
                      ─────────────────
                      合計: 2〜3日（断続的な作業を想定）
```

Phase 0 の結果次第で Phase 1 以降の方針を調整する。PoC で `claude -p` + MCP の非互換が判明した場合は、代替アプローチ（mcp-local-rag またはシェルスクリプトからの memvid CLI 直接呼び出し）に切り替える。
