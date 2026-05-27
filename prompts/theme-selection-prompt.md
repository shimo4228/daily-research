今日のデイリーリサーチのテーマを選定してください。

あなたの目的は、ユーザーが運用する複数の DOI 登録済み研究リポジトリの **概念体系の発展に寄与する最新外部研究** を、各 track につき 1 つずつ発見することです。汎用トレンドの紹介ではなく、各 repo の「裏付けが薄い概念・未解決の問い」を補強・拡張する研究を選びます。

## 手順

1. `config.toml` を読み、全 track (各 track = 1 研究 repo) の `name` / `focus` / `target_graph` / `sources` / `scoring_criteria` を把握する
2. 各 track の repo graph を Read する: `.repo-graphs/{track}.jsonld`
   - `@type` が `Concept` / `ADR` / `Axiom` / `Quadrant` / `Phase` / `ExternalReference` のノードを読み、その repo が現在持っている概念体系を理解する
   - 特に **ExternalReference (外部参照) が乏しい概念**、ADR で「未解決」「今後の課題」とされている論点に注目する
3. このプロンプト末尾の **Concept coverage report** を読む
   - 「未補強 (0 件)」「薄い (1-2 件)」の concept が補強対象の最優先候補
   - 「厚い (3+ 件)」の concept は新展開がある場合のみ再訪可
4. 各 track について、未補強・薄い concept を補強する **2026 年の最新外部研究** を WebSearch で探索する
   - 各 track の `sources` を検索の起点にする
   - 「この外部研究は repo のどの concept を、どう補強・拡張するか」を常に意識する
5. `config.toml` の `scoring_criteria` で候補を評価し、各 track 最高スコアのテーマを 1 つずつ選定する

## 出力形式

JSON のみを出力すること。説明文やマークダウンは一切含めない。
themes 配列の要素数は config.toml の track 数と一致させること（各 track 1 テーマ）。

```json
{
  "themes": [
    {
      "track": "authorship",
      "topic": "テーマのタイトル（日本語、200 文字以内）",
      "slug": "english-kebab-case-slug",
      "score": 4.2,
      "reinforces": ["https://github.com/shimo4228/authorship-strategy#concept/xxx"],
      "rationale": "補強対象の concept 名と、この外部研究がどう補強・拡張するかを 1-2 文で（500 文字以内）"
    },
    {
      "track": "contemplative",
      "topic": "...",
      "slug": "...",
      "score": 3.9,
      "reinforces": ["..."],
      "rationale": "..."
    },
    {
      "track": "aap",
      "topic": "...",
      "slug": "...",
      "score": 4.1,
      "reinforces": ["..."],
      "rationale": "..."
    }
  ]
}
```

## 制約

- track 名は config.toml の通り（`authorship` / `contemplative` / `aap`）。順不同で可
- **`reinforces`** には coverage report の角括弧 `[...]` 内に表示された concept の @id (URI) を **そのまま正確にコピー**する。Pass 2 がこれを `graph.jsonld` に記録して補強履歴を追跡するため、表記揺れ・短縮・改変があると追跡できない。1 テーマで複数 concept を補強する場合は配列に複数列挙する
- **`rationale`** には補強対象の concept 名を必ず含める（@id は reinforces に入れるので rationale には名前だけでよい）
- 未補強・薄い concept を優先する。全 track が「厚い concept の再訪」に偏るのは避ける
- `slug` は英小文字・数字・ハイフンのみ
- topic は 200 文字以内、rationale は 500 文字以内（超過すると検証で弾かれる）

---

<!-- 以下は設計メモ。LLM への指示ではない -->

## 設計メモ: モデル配置の根拠 (2026-02-20, 2026-05-27 更新)

### 現行: Opus がテーマ選定を一括担当

repo graph の読解・未補強 concept の判定・検索クエリ設計・WebSearch 実行・スコアリング・選定を Opus が一括で行う。repo の概念体系を読んで「何が足りないか」を判断する工程は深い推論を要するため Opus が適任。

### 検討・棄却した代替案

#### 案A: Opus クエリ設計 → Haiku 検索 → Opus スコアリング

Opus に検索クエリ設計だけさせ、安価な Haiku で WebSearch を実行する案。

**棄却理由:**

1. **Haiku の要約品質が Pass 1 のボトルネックになる** — Pass 1 の本質は repo concept と検索結果の突き合わせにある。Haiku では「この研究がどの concept を補強するか」の判断精度が落ち、Opus のスコアリング素材の質が下がる
2. **`claude -p` 1回追加のオーバーヘッド** — 起動 ~5-10秒、フォールバック分岐の複雑化、追加のプロンプト・バリデーションが必要
3. **コスト削減効果が微小** — Pass 1 はパイプライン全体の ~17%。内部構成を最適化しても全体コストへのインパクトは小さい

#### 案B: 3パス化 (Sonnet 検索 → Opus 判断 → Sonnet 執筆)

`docs/plans/THREE-PASS-PLAN.md` 参照。検索を Sonnet に分離し、Opus は純粋な判断のみ行う案。Opus のタイムアウト問題への対策として有効。
