# 評価フレームワーク実装プラン

## Context

daily-research パイプラインは2パス方式（Opus テーマ選定 → Sonnet リサーチ・執筆）で毎朝2本のレポートを自動生成している。前回のエージェントチーム版評価ではアドホックな LLM-as-Judge ブラインド評価を実施したが、ルーブリックが文書化されておらず再利用不可能だった。今後の機能追加のたびに品質評価が必要になるため、再利用可能な評価フレームワークを構築する。

### 設計根拠

G-Eval（Liu et al., EMNLP 2023）の方式に基づき、次元ごとに独立した judge プロンプトを使う設計とする。LLM-as-Judge の3大バイアス（Position / Verbosity / Self-preference）に対する緩和策を組み込む。

### 参考文献

- G-Eval: NLG Evaluation using GPT-4 with Better Human Alignment (EMNLP 2023) — https://arxiv.org/abs/2303.16634
- LLMs-as-Judges: A Comprehensive Survey on LLM-based Evaluation Methods (Dec 2024, NeurIPS) — https://arxiv.org/abs/2412.05579
- A Survey on LLM-as-a-Judge (Nov 2024) — https://arxiv.org/abs/2411.15594
- Self-Preference Bias in LLM-as-a-Judge (Oct 2024) — https://arxiv.org/abs/2410.21819
- Justice or Prejudice? Quantifying Biases in LLM-as-a-Judge (Oct 2024) — https://arxiv.org/abs/2410.02736
- RESEARCHRUBRICS Benchmark (Scale AI) — https://static.scale.com/uploads/654197dc94d34f66c0f5184e/DR_Benchmark_0914_v1%20(5).pdf
- Building an LLM Evaluation Framework: Best Practices (Datadog) — https://www.datadoghq.com/blog/llm-evaluation-framework-best-practices/
- Beyond Prompts: A Data-Driven Approach to LLM Optimization (Statsig) — https://www.statsig.com/blog/llm-optimization-online-experimentation

---

## ルーブリック (6次元 × 5点 = 30点満点)

| # | 次元 | アンカー 1 | アンカー 3 | アンカー 5 |
|---|------|-----------|-----------|-----------|
| 1 | Factual Grounding (事実的根拠) | 出典なし/捏造の疑い | 5件以上の出典、一部未検証 | 全主張に信頼できる一次情報源 |
| 2 | Depth of Analysis (分析の深さ) | プレスリリースの要約レベル | 「なぜ重要か」の説明あり | 専門家レベルの統合・洞察 |
| 3 | Coherence (構成・流暢性) | 断片的、論理の飛躍 | セクション間の流れは自然 | シームレスな散文、読みやすいリズム |
| 4 | Specificity (具体性) | 抽象的記述のみ | 固有名詞・数字あり | 豊富な事例・数値・比較 |
| 5 | Novelty (テーマ斬新さ) | 周知・陳腐 | タイムリーだが予測可能 | 非自明で先見性あり |
| 6 | Actionability (行動可能性) | 開発アイデアが漠然 | 具体的だが深掘り不足 | 即座に着手可能なレベル |

---

## 実装するファイル

### 新規作成

| ファイル | 目的 |
|---------|------|
| `docs/plans/eval-framework-plan.md` | 本プランの永続化（論文URL含む） |
| `scripts/eval-run.sh` | 評価メインスクリプト |
| `evals/prompts/judge-system.md` | judge 共通システムプロンプト |
| `evals/prompts/judge-factual.md` | Factual Grounding 評価プロンプト |
| `evals/prompts/judge-depth.md` | Depth of Analysis 評価プロンプト |
| `evals/prompts/judge-coherence.md` | Coherence 評価プロンプト |
| `evals/prompts/judge-specificity.md` | Specificity 評価プロンプト |
| `evals/prompts/judge-novelty.md` | Novelty 評価プロンプト |
| `evals/prompts/judge-actionability.md` | Actionability 評価プロンプト |
| `evals/scores.jsonl` | スコアログ（追記専用、.gitignore） |
| `evals/scores.example.jsonl` | スキーマ確認用サンプル（Git 管理） |
| `tests/test-eval.bats` | 評価スクリプトのテスト |

### 変更

| ファイル | 変更内容 |
|---------|---------|
| `scripts/daily-research.sh` (L289-295) | Pass 2 成功時に eval-run.sh を呼ぶフック追加 |
| `CLAUDE.md` | Directory Structure に evals/ を追加、評価の説明 |
| `.gitignore` | `evals/scores.jsonl` を追加（個人データ） |

---

## 実装手順

### Step 1: ディレクトリ構造とプラン文書 ✅

- `evals/prompts/` ディレクトリを作成
- `evals/reports/` ディレクトリを作成
- 本プランを `docs/plans/eval-framework-plan.md` に保存

### Step 2: Judge プロンプトの作成 (7ファイル)

`evals/prompts/judge-system.md` — 全次元で共有するシステムプロンプト:
- 役割定義: 「リサーチレポートの品質評価者」
- バイアス緩和の共通指示:
  - 「レポートの長さはスコアに影響させないこと」(anti-verbosity)
  - 「散文の流暢さに惑わされず、内容の正確さと深さで判断すること」(anti-self-preference)
- 出力フォーマット: `{"score": N, "rationale": "..."}`（JSON のみ）

`evals/prompts/judge-{dimension}.md` (6ファイル) — 各次元の評価指示:
- アンカー説明（1, 3, 5 の具体的基準）
- 評価すべき観点のチェックリスト
- `{ARTICLE_CONTENT}` プレースホルダ

### Step 3: eval-run.sh の実装

```
eval-run.sh の処理フロー:
1. 引数: DATE, VAULT_PATH (daily-research.sh から渡される)
2. 当日のレポートファイルを Glob で特定
3. 各レポートに対して 6次元のループ:
   a. judge-system.md + judge-{dimension}.md を結合
   b. レポート本文を {ARTICLE_CONTENT} に注入
   c. claude -p (Opus, --max-turns 1) で評価実行
   d. JSON レスポンスからスコアを抽出
4. 全スコアを evals/scores.jsonl に 1行で追記
5. サマリーをログに出力
```

設計ポイント:
- `--max-turns 1` で1往復に制限（judge は検索不要）
- `--model claude-opus-4-6` で Sonnet ライターとは別ティアの judge
- `--output-format json` で Claude CLI の JSON ラッパーから結果を抽出
- `--allowedTools ""` — ツール不要（読むだけ）
- 1次元ずつ独立呼び出し（G-Eval 推奨: 一括採点は信頼性が下がる）
- 評価失敗は daily-research.sh の成功/失敗に影響させない

### Step 4: daily-research.sh への統合

`scripts/daily-research.sh` L289-295 を変更:

```bash
if [ $PASS2_EXIT -eq 0 ]; then
  log "=== Completed successfully ==="
  notify "今朝のリサーチレポートが完成しました" "Daily Research"

  # === 品質評価 ===
  log "=== Starting evaluation ==="
  "$PROJECT_DIR/scripts/eval-run.sh" "$DATE" "$VAULT_PATH" >> "$LOG_FILE" 2>&1 || {
    log "WARN: Evaluation failed (non-fatal)"
  }
fi
```

評価失敗は本体の exit code に影響させない。

### Step 5: .gitignore と config

- `.gitignore` に `evals/scores.jsonl` を追加（スコアは個人データ）
- `evals/scores.example.jsonl` にサンプル1行を置く（Git 管理）

### Step 6: テスト

`tests/test-eval.bats`:
- `eval-run.sh` の構文チェック (`bash -n`)
- judge プロンプトファイルの存在チェック
- `{ARTICLE_CONTENT}` プレースホルダの存在チェック
- `scores.jsonl` のスキーマバリデーション（サンプル行で）
- judge-system.md にバイアス緩和指示が含まれていることの確認

### Step 7: CLAUDE.md 更新

Directory Structure に `evals/` を追加。評価の運用ルール:
- `pipeline_version` は機能変更時に手動で更新する
- n < 20 の比較は「暫定シグナル」とラベル

---

## scores.jsonl スキーマ

```json
{
  "date": "2026-02-21",
  "pipeline_version": "2pass-opus-sonnet",
  "track": "tech",
  "slug": "xcode-26-agentic-coding-mcp",
  "scores": {
    "factual_grounding": 4,
    "depth_of_analysis": 3,
    "coherence": 5,
    "specificity": 4,
    "novelty": 3,
    "actionability": 4
  },
  "total": 23,
  "judge_model": "claude-opus-4-6",
  "eval_duration_s": 42
}
```

- 1行1レポート、追記専用
- `pipeline_version`: 手動タグ（機能変更時に更新）
- `judge_model`: judge 変更の影響追跡用

---

## 統計規律

| サンプル数 | 主張できること | 検定手法 |
|-----------|--------------|---------|
| n < 10 | 方向性のみ（「暫定シグナル」） | なし |
| n = 10〜30 | 有意差検出（効果量 ≥ 0.5 SD） | Wilcoxon signed-rank test |
| n ≥ 30 | 安定した比較 | paired t-test |

バージョン比較は n ≥ 20 に達してから実施する。
差 ≥ 2点/30点 (≥ 7%) で有意とみなす。

---

## コスト見積もり

- 12 Opus calls/日 (2記事 × 6次元)
- 各 call: ~$0.01-0.015 (短いプロンプト + 短い応答)
- 日額: ~$0.12-0.18
- 月額: ~$4-5
- 年額: ~$50-55

---

## 検証方法

1. `bats tests/test-eval.bats` — 構文・構造テスト
2. 手動で `eval-run.sh` を当日レポートに対して実行し、scores.jsonl の出力を確認
3. scores.jsonl のスコアを目視で妥当性確認（極端な 1 や 5 がないか）
4. 翌朝の launchd 実行で daily-research.sh + eval-run.sh が連携動作することを確認
