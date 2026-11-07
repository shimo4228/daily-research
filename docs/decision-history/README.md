# 判断の経緯（Decision History）

この repo で何を決め、なぜそうしたかの記録。1 件 1 ファイル、番号は連番、過去形で書く。
記録は書かれた日の判断で、現行はコード・prompt・設定・`CLAUDE.md` と著者の今の指示が決める。旧記録の Status 欄も
その日の状態。新しい判断は旧記録と衝突してよく、旧記録はそのまま置く。

| ID | Title | Date |
|---|---|---|
| 0001 | daily-research を汎用トレンドリサーチから 3 研究 repo の R&D フィードバックエンジンへ転換 | 2026-05-27 |
| 0002 | signal-first 原則の出力側双対 — レポートをフロンティア差分として定義する | 2026-06-29 |
| 0003 | daily-research を複数研究ラインにまたがる知識環流エンジンとして認識する | 2026-06-29 |
| 0004 | 4 track を 3 ライン (2 repo-backed + 1 自由探索) に再編し、飽和 repo に frontier モードを導入する | 2026-07-07 |
| 0005 | 4ラインを Agent Systems + AI協働型公共圏 + Tech + Human Adaptation に再編する | 2026-07-19 |
| 0006 | 自己改善ループを「決定論収集 + 人間 consumer」で構成し、LLM judge を復活させない | 2026-07-29 |
| 0007 | 自由探索 line を全廃し、4 研究 repo への 1:1 コンセプト補強構成へ回帰する | 2026-07-31 |
| 0008 | per-repo in-context research へ全面移行し、concept-graph 駆動のテーマ選定を retire する | 2026-08-04 |
| 0009 | 解説レポートへの転換と 7:00 承認ブリーフの廃止 (ADR-0008 の目的関数を修正) | 2026-08-05 |
| 0010 | rotation 単一 line 実行と in-loop 二層 eval (テーマ選別 / clarity 改稿) の導入 | 2026-08-13 |
| 0011 | daily line (毎日実行 line) の導入と部分失敗セマンティクス | 2026-08-14 |
| 0012 | desire line を daily から輪番へ戻す (毎朝 1 本・6 line 周期) | 2026-08-18 |
| 0013 | edge line (AI 活用の限界突破事例) を daily で新設する | 2026-08-20 |
| 0014 | レポートを「動向解説 + repo への含意」へ単純化し、対立的フレーミングを撤去する | 2026-08-22 |
| 0015 | レポートの読者契約を文体規律として共通化し、edge line を手筋収穫型へ改修する | 2026-08-27 |
| 0016 | 発見を中心に据えた日刊号へ再編する | 2026-09-06 |
| 0017 | per-repo 輪番へ戻し、3 line/日の window・4 内容状態・原典照合 pass・問い粒度の履歴を導入する | 2026-09-14 |
| 0018 | 接地 repo を持たない ecosystem mode を追加し、Jev エコシステム観測 line を daily で新設する | 2026-09-21 |
| 0019 | 広域 line を daily で置き per-repo を 1 日 1 本にし、呼び出しの土台と run ごとの記帳を削る | 2026-10-31 |

## Template

新しい記録の節: Date / Context / Decision / Review-when / Alternatives Considered / Consequences。
Decision は過去形（何をしたかと理由）で書く。Review-when（考え直す観測・前提の失効）は任意で、無ければ
「無し — 記録」と書く。

File name: `NNNN-kebab-case-title.md` (zero-padded 4-digit sequence).
