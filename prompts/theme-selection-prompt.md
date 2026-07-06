今日のデイリーリサーチのテーマを選定してください。

あなたの目的は、各研究ライン (line) につき 1 つずつテーマを発見することです。line には 2 種類あります:

- **repo-backed line** (`repos` を持つ): ユーザーが運用する DOI 登録済み研究リポジトリの **概念体系の発展に寄与する最新外部研究** を選ぶ。寄与のしかたは repo ごとの選定モード (coverage / frontier) で変わる
- **自由探索 line** (`repos` を持たない): 研究ラインの既存領域の **外** からセレンディピティを拾う。飽和 cluster を避け、未踏領域の新しい動きを選ぶ

## 選定モード

各 repo のモードはプロンプト末尾の **Concept coverage report** が `MODE:` として判定済みです:

- **coverage** — repo にまだ未補強・薄い concept がある。それらを補強する外部研究を選ぶ (従来通りの gap 埋め)。厚い concept の再訪は新展開がある時のみ
- **frontier** — repo の全 concept が既に厚い (gap 埋め完了)。**gap を探すのをやめ**、次を探す:
  1. repo の concept に **挑戦・矛盾** する研究 (反証、限界の指摘、対立フレームワーク)
  2. repo の concept を **拡張** する研究 (新しい適用領域、精緻化、隣接理論との接続)
  3. repo にまだ存在しない **新 concept 候補** になる研究
  coverage report の **『常設フロンティア質問』を最優先の探索軸** にすること
- **explore** — 自由探索 line 専用。プロンプト末尾の **Cluster saturation report** の飽和 cluster を避け、過去テーマと重ならない未踏領域から選ぶ

2 repo を持つ line では、片方の repo に絞ったテーマでも、両 repo の concept を横断する **交差テーマ** でもよい。交差テーマは単独 repo では出ない新規性を持つため歓迎される (その場合 `repos` に両方の key を列挙する)。

## 手順

1. `config.toml` を読み、全 line の `name` / `focus` / `repos` / `sources` / `scoring_criteria` を把握する
2. repo-backed line について、各 repo の graph を Read する: `.repo-graphs/{key}.jsonld`
   - `@type` が `Concept` / `ADR` / `Axiom` / `Quadrant` / `Phase` / `ExternalReference` のノードを読み、その repo の概念体系を理解する
3. このプロンプト末尾の **Concept coverage report** を読む
   - 各 repo の `MODE:` に従って探索目的を切り替える (上の「選定モード」参照)
   - 各 concept の「既出:」行は、その concept に言及した過去レポート。**既出レポートと同じ外部研究を主ソースに再利用してはならない**（別 concept 宛てでも不可）
   - 「repo 取り込み済み外部文献」は repo が既に引用している文献。**これらを主ソースとするテーマは新規性ゼロなので選定禁止**（後続研究・新展開は可）
4. 自由探索 line について、このプロンプト末尾の **Cluster saturation report** を読む
   - 飽和 cluster に主に属するテーマは選定禁止。低頻度・新規 cluster を優先
5. このプロンプト末尾の **過去テーマ履歴** を読み、テーマ・主ソースが重複していないか確認する
6. 各 line について、モードに適合する **2026 年の最新外部研究** を WebSearch で探索する
   - 各 line の `sources` を検索の起点にする
   - repo-backed line では「この外部研究は repo のどの concept を、どう補強 (coverage) / 挑戦・拡張 (frontier) するか」を常に意識する
7. `config.toml` の `scoring_criteria` で候補を評価し、各 line 最高スコアのテーマを 1 つずつ選定する

## 出力形式

JSON のみを出力すること。説明文やマークダウンは一切含めない。
themes 配列の要素数は config.toml の line 数と一致させること（各 line 1 テーマ）。

```json
{
  "themes": [
    {
      "track": "attribution",
      "repos": ["authorship"],
      "mode": "coverage",
      "topic": "テーマのタイトル（日本語、200 文字以内）",
      "slug": "english-kebab-case-slug",
      "score": 4.2,
      "reinforces": ["https://github.com/shimo4228/authorship-strategy#concept/xxx"],
      "challenges": [],
      "extends": [],
      "rationale": "補強対象の concept 名と、この外部研究がどう補強するかを 1-2 文で（500 文字以内）"
    },
    {
      "track": "agent_cognition",
      "repos": ["akc", "contemplative"],
      "mode": "frontier",
      "topic": "...",
      "slug": "...",
      "score": 3.9,
      "reinforces": [],
      "challenges": ["https://.../vocab#concept/yyy"],
      "extends": ["https://.../vocab#concept/zzz"],
      "rationale": "挑戦・拡張対象の concept 名と、この外部研究がどう挑戦・拡張するかを 1-2 文で"
    },
    {
      "track": "tech",
      "repos": [],
      "mode": "explore",
      "topic": "...",
      "slug": "...",
      "score": 4.0,
      "reinforces": [],
      "challenges": [],
      "extends": [],
      "rationale": "どの未踏 cluster に属し、なぜ今注目かを 1-2 文で"
    }
  ]
}
```

## 制約

- track 名・repos の key は config.toml の通り。順不同で可
- **`repos`** には寄与先 repo の `key` を入れる（config.toml の `[[tracks.X.repos]]` の `key`）。交差テーマなら複数列挙。自由探索 line は空配列
- **`mode`** は coverage report の `MODE:` 判定に従う。repo-backed line は `coverage` / `frontier`、自由探索 line は `explore`。1 テーマで複数 repo に寄与しモードが混在する場合は主たる寄与先のモードを書く
- **`reinforces` / `challenges` / `extends`** には対象 concept の @id を入れる。coverage report の角括弧 `[...]` 内の完全 URI、またはその fragment (`#` 以降、例 `concept/attribution-diffusion`) のどちらでもよい (coverage-report は `#` 以降で正規化照合する)。使い分け:
  - `reinforces` — concept を裏付け・補強する (coverage モードの主フィールド。非空必須)
  - `challenges` — concept に挑戦・矛盾する (frontier モード)
  - `extends` — concept を拡張する (frontier モード)。frontier では 3 つの union が非空であること
  - explore (自由探索) は 3 つとも空
- **`rationale`** には対象 concept 名を必ず含める（repo-backed line の場合。@id は関係フィールドに入れるので rationale には名前だけでよい）
- **ソース単位の重複禁止**: 同一の外部研究（論文・プロジェクト・ベンチマーク）を主ソースとするテーマは、過去テーマ履歴・coverage report の「既出:」・「repo 取り込み済み外部文献」のいずれかに登場していたら選定しない。宛先 concept を変えての再利用も不可。例外は後続研究・新展開のみで、その場合は rationale に「何が新しいか」を必ず明記する
- `slug` は英小文字・数字・ハイフンのみ
- topic は 200 文字以内、rationale は 500 文字以内（超過すると検証で弾かれる）

---

<!-- 以下は設計メモ。LLM への指示ではない -->

## 設計メモ: モデル配置の根拠 (2026-02-20, 2026-05-27, 2026-07-07 更新)

### 現行: Opus がテーマ選定を一括担当

repo graph の読解・モード判定の解釈・検索クエリ設計・WebSearch 実行・スコアリング・選定を Opus が一括で行う。repo の概念体系を読んで「何が足りないか / 何に挑戦できるか」を判断する工程は深い推論を要するため Opus が適任。

coverage / frontier のモード判定自体は決定論的に coverage-report (dr_pipeline.py) が行い、Opus はその判定を前提に探索する (code-owned decision + LLM execution)。

### 検討・棄却した代替案

#### 案A: Opus クエリ設計 → Haiku 検索 → Opus スコアリング

Opus に検索クエリ設計だけさせ、安価な Haiku で WebSearch を実行する案。

**棄却理由:**

1. **Haiku の要約品質が Pass 1 のボトルネックになる** — Pass 1 の本質は repo concept と検索結果の突き合わせにある。Haiku では「この研究がどの concept を補強するか」の判断精度が落ち、Opus のスコアリング素材の質が下がる
2. **`claude -p` 1回追加のオーバーヘッド** — 起動 ~5-10秒、フォールバック分岐の複雑化、追加のプロンプト・バリデーションが必要
3. **コスト削減効果が微小** — Pass 1 はパイプライン全体の ~17%。内部構成を最適化しても全体コストへのインパクトは小さい

#### 案B: 3パス化 (Sonnet 検索 → Opus 判断 → Sonnet 執筆)

検索を Sonnet に分離し、Opus は純粋な判断のみ行う案。Opus のタイムアウト問題への対策として有効。
