# verify-golden — 呼2（検証 + clarity）の見逃し・過剰修正を手で確かめる fixture

呼2 が書く `verify.json` の件数は自己申告で、見逃し（誤りを supported にする）は測れない。
この fixture は**既知の誤りを植えた原稿**と根拠ファイルで、呼2 を手動で当てて検出数を数える
（ADR-0017 Review-when。launchd には入れない — 自動 test ではない）。

## 中身

- `report.md` — 4 件の主張を持つ短い原稿。植えた誤りは下の表のとおり。
- `evidence.md` — 呼1 が書く根拠ファイルと同じ形の主張表。URL はすべて arXiv の abs ページ（本文が公開で
  WebFetch できる）。

| claim | 植えた誤り | 期待する判定 |
|---|---|---|
| C1 | 発表年を 2024 年と書いた（arXiv 2510.01171 は 2025-10） | partial → 日付を訂正 |
| C2 | 課題数を 1,000 件と書いた（DeepResearch Bench は 100 件） | partial → 数値を訂正 |
| C3 | WebWeaver の作者を Anthropic と書いた（Tongyi Lab） | partial → 話者を訂正 |
| C4 | CiteGuard が「recall 90% を報告」と書いた（原典にそのような数値はない） | unsupported → 文を削るか原典の記述に置換 |
| C5 | 正しい主張（対照。Kim et al. が 180 構成を比較） | supported → 無変更 |

## 手順（所要 5〜10 分、費用 $1 前後）

```bash
cd /path/to/daily-research
cp tests/fixtures/verify-golden/report.md /tmp/verify-golden-report.md
claude -p "以下のレポートを、システムプロンプトに追記された verification プロトコルに従って clarity 改稿し、最後に主要な主張を原典で照合してください。
対象ファイル (原稿): /tmp/verify-golden-report.md
根拠ファイル (読み取りのみ): $PWD/tests/fixtures/verify-golden/evidence.md
検証結果の書き込み先: /tmp/verify-golden.verify.json
書き込みはこの 2 ファイルだけ。" \
  --permission-mode default \
  --append-system-prompt-file prompts/verification-protocol.md \
  --allowedTools "Read,WebFetch,Edit(///tmp/verify-golden-report.md),Edit(///tmp/verify-golden.verify.json)" \
  --disallowedTools "Bash,Task,NotebookEdit,WebSearch" \
  --max-turns 30 --model sonnet --output-format json --no-session-persistence
diff tests/fixtures/verify-golden/report.md /tmp/verify-golden-report.md
cat /tmp/verify-golden.verify.json
```

## 記録するもの

- 検出: C1〜C4 のうち partial / unsupported と判定された数（期待 4）。
- 過剰修正: C5 を触ったか（期待: 触らない）。訂正以外の span 編集の数。
- 訂正の中身: 数値・年・話者が原典どおりになったか。「〜と報じられている」への言い換えで済ませていないか。

結果は `/dr-review` の記録に日付つきで残す。4 件中 2 件以下しか検出できない場合は `[verification] model` を
opus にして再試行し、それでも同じなら照合規則（`prompts/verification-protocol.md` Step B）を直す。
