今日のデイリーリサーチのテーマを2つ選定してください。

## 手順

1. `config.toml` を読み、各トラック（tech / personal）の対象ドメインとスコアリング基準を把握する
2. `past_topics.json` を読み、過去30日以内のテーマと重複しないよう確認する
3. WebSearch で最新トレンドを調査する
4. config.toml のスコアリング基準で候補を評価し、各トラック最高スコアのテーマを1つずつ選定する

## 出力形式

JSON のみを出力すること。説明文やマークダウンは一切含めない。

```json
{
  "themes": [
    {
      "track": "tech",
      "topic": "テーマのタイトル（日本語）",
      "slug": "english-kebab-case-slug",
      "score": 4.2,
      "rationale": "選定理由を1-2文で"
    },
    {
      "track": "personal",
      "topic": "テーマのタイトル（日本語）",
      "slug": "english-kebab-case-slug",
      "score": 3.8,
      "rationale": "選定理由を1-2文で"
    }
  ]
}
```
