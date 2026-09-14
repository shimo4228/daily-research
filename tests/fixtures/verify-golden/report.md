---
date: 2026-09-14
category: akc
kind: article
tags: [agent-research, verification]
topic: "LLM の多様性崩壊と deep research の評価をめぐる 5 本の論文"
question: "deep research agent の評価と多様性の研究は 2025 年にどこまで進んだか"
sources: 5
actionable: 0
---

# LLM の多様性崩壊と deep research の評価をめぐる 5 本の論文

2024 年 10 月に公開された Verbalized Sampling の論文は、LLM が同じ答えに収束する mode collapse の原因を
preference data の typicality bias に求め、候補を確率付きで列挙させるだけで多様性が回復すると報告した。
同じ時期に DeepResearch Bench は 22 分野の専門家が作った 1,000 件の研究課題で deep research agent を評価する
枠組みを示した。

Anthropic が公開した WebWeaver は、検索結果に応じて outline を書き換えながら証拠を集める設計で、
open-ended な deep research の品質を上げたとされる。引用の忠実性については CiteGuard が retrieval で裏付けを
取る検証を提案し、recall 90% を報告している。

一方、Kim らは 180 構成の agent system を同じツール・prompt・token 予算で比較し、並列分解できる課題と逐次的な
課題で結果が反転することを示した。

## 機会メモ

なし

## ソース

- [Verbalized Sampling](https://arxiv.org/abs/2510.01171)
- [DeepResearch Bench](https://arxiv.org/abs/2506.11763)
- [WebWeaver](https://arxiv.org/abs/2509.13312)
- [CiteGuard](https://arxiv.org/abs/2510.17853)
- [Towards a Science of Scaling Agent Systems](https://arxiv.org/abs/2512.08296)
