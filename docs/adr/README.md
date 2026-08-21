# Architecture Decision Records

| ID | Title | Status | Date |
|---|---|---|---|
| 0001 | daily-research を汎用トレンドリサーチから 3 研究 repo の R&D フィードバックエンジンへ転換 | Accepted | 2026-05-27 |
| 0002 | signal-first 原則の出力側双対 — レポートをフロンティア差分として定義する | Accepted | 2026-06-29 |
| 0003 | daily-research を複数研究ラインにまたがる知識環流エンジンとして認識する | Accepted | 2026-06-29 |
| 0004 | 4 track を 3 ライン (2 repo-backed + 1 自由探索) に再編し、飽和 repo に frontier モードを導入する | Superseded by 0007 / 0008 | 2026-07-07 |
| 0005 | 4ラインを Agent Systems + AI協働型公共圏 + Tech + Human Adaptation に再編する | Superseded by 0007 / 0008 | 2026-07-19 |
| 0006 | 自己改善ループを「決定論収集 + 人間 consumer」で構成し、LLM judge を復活させない | Accepted | 2026-07-29 |
| 0007 | 自由探索 line を全廃し、4 研究 repo への 1:1 コンセプト補強構成へ回帰する | Superseded by 0008 | 2026-07-31 |
| 0008 | per-repo in-context research へ全面移行し、concept-graph 駆動のテーマ選定を retire する | Amended by 0009, 0010, 0014 | 2026-08-04 |
| 0009 | 解説レポートへの転換と 7:00 承認ブリーフの廃止 (ADR-0008 の目的関数を修正) | Amended by 0014 | 2026-08-05 |
| 0010 | rotation 単一 line 実行と in-loop 二層 eval (テーマ選別 / clarity 改稿) の導入 | Amended by 0011, 0014 | 2026-08-13 |
| 0011 | daily line (毎日実行 line) の導入と部分失敗セマンティクス | Amended by 0012 | 2026-08-14 |
| 0012 | desire line を daily から輪番へ戻す (毎朝 1 本・6 line 周期) | Accepted | 2026-08-18 |
| 0013 | edge line (AI 活用の限界突破事例) を daily で新設する | Accepted | 2026-08-20 |
| 0014 | レポートを「動向解説 + repo への含意」へ単純化し、対立的フレーミングを撤去する | Accepted | 2026-08-22 |

## Template

ADRs in this repository use the 6-section template:
Status / Date / Context / Decision / Alternatives Considered / Consequences.
From 0014 on, a `## Review-when` section (expiry conditions for the decision) is
added after Decision, following the harness ADR convention.

File name: `NNNN-kebab-case-title.md` (zero-padded 4-digit sequence).
