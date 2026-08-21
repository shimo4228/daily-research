---
name: dr-review
description: daily-research の自己改善レビュー (ADR-0006)。metrics.jsonl の運用トレンド・決定論 lint・wiki 品質注記・DR-Expect 突合を集計し、改善候補を人間の判断材料として提示する。ユーザーが「dr review」「パイプラインの調子を見て」「daily-research の改善レビュー」と言ったとき、または /dr-review で起動。週 1 目安。判断と改善の着手はユーザーが行う — この skill は材料整形まで。
user-invocable: true
origin: shimo4228
---

# /dr-review — daily-research 自己改善レビュー

毎朝の自律実行が蓄積した計測データを人間の改善判断に翻訳するレビュー。
**consumer は人間** — この skill は LLM による品質再採点をせず、決定論的に収集された
signal の集計と解釈だけを行い、改善するかどうか・何を変えるかはユーザーが決める
(ADR-0006。旧 LLM-as-Judge は「スコアを消費する下流の不在」で死んだ — 同じ轍を踏まない)。

## 手順

すべて repo root (`~/MyAI_Lab/daily-research`) で実行する。python3 は
`/opt/homebrew/bin/python3` (tomllib 必須)。

### 1. telemetry 集計

```bash
python3 scripts/lib/dr_pipeline.py metrics-backfill metrics.jsonl logs   # ログ残存分の救済 (冪等)
```

`metrics.jsonl` を読み、直近 30 日について以下を集計・提示する:

- Pass1 / Pass2 の turns 分布 (p50 / p90 / max) と **設定中の `--max-turns` との余白**
  (daily-research.sh の `--max-turns` 値と比較。p90 が上限に接近していたら警告)
- total_cost の推移 (mean / max、異常スパイク)
- fallback 発動率と、`final_class != "OK"` の失敗一覧
- report_count = 0 の日 (silent fail の残骸。rotation 後は呼1 失敗 = その日 0 本)
- **clarity_pass (呼2、ADR-0010)**: ran/ok 率と cost/turns。ok=false が続くなら
  呼2 の timeout / max-turns / プロトコルの見直し候補

### 2. 品質 signal

```bash
python3 scripts/lib/dr_pipeline.py report-lint "<vault>/daily-research" "$(date +%Y-%m-%d)" config.toml
python3 scripts/lib/dr_pipeline.py wiki-quality-scan "<vault>" 30 config.toml
```

- lint: metrics.jsonl 内の蓄積分から hard / soft violation のトレンドを出す
- wiki-quality-scan: line 別 FLAGGED 率 (一次未照合・推定扱い注記) を提示。
  特定 line に偏っていたら research-protocol.md の出典照合指示の弱点候補
- **本文字数の推移 (ADR-0014)**: lint 出力の `results[].body_chars` (metrics.jsonl の
  `lint` にも入る) を line 別に見る。目安は 3,000 字以内 — 超過が常態化したら
  プロトコル Step 5 の長さ指示が効いていない signal (機械 lint は意図的に置かない)
- **可読性の主観判定 (ADR-0014 Review-when)**: 2026-08-30 に 2026-08-23 以降の 7 日分を
  通読し「最後まで読めたか / repo に使えたものがあったか」を判定する。
  `theme_rank` 分布の集計は ADR-0014 で廃止した (frontmatter に無い)

### 3. DR-Expect 突合 (改善変更の効果検証)

前回 review 以降の prompt / config / script 変更 commit から trailer を拾い、実測と突合する:

```bash
# 1 commit に複数 DR-Expect がある場合、2 行目以降に date が付かないため awk で引き継ぐ
git log --since="<前回 review 日>" --date=short \
    --format='%ad%x09%(trailers:key=DR-Expect,valueonly)' \
  | awk -F'\t' 'NF==2 { d=$1; if ($2!="") print d "\t" $2; next }
                NF==1 && $1!="" { print d "\t" $1 }' \
  | python3 scripts/lib/dr_pipeline.py expect-check metrics.jsonl
```

verdict (ACHIEVED / NOT_ACHIEVED / INSUFFICIENT_DATA) をそのまま提示する。
NOT_ACHIEVED は「変更が意図した効果を出していない」— revert 候補または再調整候補。

### 4. repo 還元トレース (best-effort)

各研究 repo の wiki-harvest ledger (`~/MyAI_Lab/*/.notes/`) に daily-research 由来の
還元記録があれば件数を出す。取れなければ「データなし」と正直に言う (silent cap 禁止)。

### 5. 改善候補の提示と record

集計から**行動を変える観察だけ**を改善候補として提示する (スコアや等級を出さない —
signal-first)。各候補に根拠 (どの数字か) と対象ファイルを添える。**採否はユーザー**。

レビュー完了時に state を更新する:

```bash
python3 -c "import json,datetime,os; os.makedirs('.notes',exist_ok=True); json.dump({'last_review': datetime.date.today().isoformat()}, open('.notes/dr-review-state.json','w'))"
```

## DR-Expect trailer 規約 (正本)

prompt / config / script の**効果を意図した変更**の commit には、期待を機械可読 1 行で残す:

```
feat: Pass 1 の max-turns を 15 → 25 に引き上げ

DR-Expect: pass1_turns_p90 <= 20
DR-Expect: fallback_rate <= 0.05
```

- 書式: `DR-Expect: <metric> <op> <value>`。op は `<= >= == < >`
- metric 語彙 (expect-check が解釈する):
  `pass1_turns_p50|p90|max` / `pass2_turns_p50|p90|max` /
  `pass1_cost_mean|max` / `pass2_cost_mean|max` / `total_cost_mean|max` /
  `fallback_rate` / `report_count_min` / `no_report_count` / `lint_hard_count`
- 評価窓は「commit 日より後の全 record」。次回 review で自動突合される
- 期待が書けない変更 (doc 修正等) に無理に付けない。付けた期待が NOT_ACHIEVED でも
  それ自体は失敗ではない — 効果が出ていない事実が見えることが目的

## 規律

- この skill は**読み取りと集計のみ**。prompt / config の変更はユーザーの採否決定後に
  通常の実装フロー (Verify ゲート込み) で行う
- 改善を採用する commit には DR-Expect を付け、次回 review でループを閉じる
- metrics.jsonl は個人データ (gitignore 済み)。レビュー内容を public repo の doc に
  書くときはコスト実数値を含めない
