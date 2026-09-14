# ADR-0012: desire line を daily から輪番へ戻す (毎朝 1 本・6 line 周期)

## Status

Accepted (ADR-0011 の決定 5 を撤回。決定 1〜4 の daily 機構は残す)

## Date

2026-08-18

## Context

ADR-0011 (2026-08-14) は `desire` line を `daily = true` で毎日実行する構成を採り、「desire も輪番に入れる (6 日周期)」を「証言出現の捕捉が最大 6 日遅れ、出現瞬間の定点観測と矛盾する」として棄却した。

4 日間 (2026-08-15〜18) の実測:

- レポート 4 本はいずれも repo (desire-frontier) の語彙・境界・仮説を動かす高収率だったが、その収率の源は**外部の日次の動きではなく未読在庫の消化**だった。08-17 の Imas 系列は 2026-04〜06 の資料、08-18 の証言 3 本は 2025-06〜2026-02 の記事で、レポート自身が「鮮度では B 相当」「今日の外部の動きではない」と明記している
- line の中心タスクである枯渇型一人称証言の出現は、英語圏 2 本・日本語圏 0 本の baseline が 5 日間動いていない。08-18 レポートは「公開が制作より先に止まるなら測定器は前線に近づくほど感度を失う」という構造説を立て、日次で監視しても捕捉が早まる保証がないことを示した
- 定点 source の多く (Borretti / Wenbo Pan / Matuschak / Altman / Crooked Dandy) は月〜年単位の更新で、日次 cadence では「変化なし」の確認に run の大半を使う。Matuschak と Altman は差分検出自体が不能と判定された

運用者 (著者) は 2026-08-18 に「そのうち飽和してくるのだろう」と評し、日次レポートを他 repo との輪番に戻して毎朝 1 本にするよう指示した。

## Decision

1. `config.toml` の `[tracks.desire]` から `daily = true` を外す。`rotation-pick` は 6 line (akc / contemplative / aap / authorship / ans / desire、config 記述順) の `epoch 日 % 6` で毎朝 1 line を選ぶ。desire の初回は 2026-08-19 (序数 % 6 = 5)
2. daily 機構 (ADR-0011 決定 1〜4: schema / per-line ループ / E_PARTIAL / metrics 合算) は削除しない。使用 line が無いだけで、将来「速い line」が現れたら再利用する
3. desire-frontier repo 側の手動 ingest (レポート → concepts / reading-list / testimonies / README / essays) は cadence に依存しないので変更なし。README の「観測ループ」節の「毎日」表記は repo 側で同期する

## Alternatives Considered

- **daily を維持し Sonnet + 低 max-turns で軽量化する** (ADR-0011 が保留した案): コストは下がるが、収率の源が在庫消化である問題は解けない — 軽量化しても在庫が尽きれば「変化なし」を毎日書く。輪番でも在庫消化は 6 日ごとに進む。棄却
- **desire を週 2 回など中間 cadence にする**: rotation-pick は「輪番 1 + daily 全行」の 2 段階しか持たず、任意周期には新機構が要る。ADR-0011 の Consequences が「速い line / 遅い line の cadence 分離」に daily フラグを再利用できると書いたが、現時点で中間 cadence を正当化する観測がない。棄却 (必要になったら再検討)
- **desire line を停止する**: 証言出現の定点観測は「見つからない」も baseline データであり、6 日周期でも系列は続く。停止は系列を切る。棄却

## Consequences

- 良: 毎朝 1 本に戻り、日次コスト・wall-clock は ADR-0010 水準 (約 $4.5 / 最悪 40 分) へ戻る。他 5 line の位相は `% 5` → `% 6` で変わる (2026-08-19 が desire、08-20 が akc、以降 config 順)
- 良: desire レポートの収率が「在庫消化」から「外部の動き」へ移ったかを、6 日間隔で見比べやすくなる (飽和の判定材料)
- 悪: 証言出現の捕捉遅延が最大 6 日に戻る (ADR-0011 が棄却した理由そのもの)。日次証言の量産期 (5 年較正では数年先) が来たら ADR-0011 の構成へ戻す — 失効条件: 枯渇型証言が週 1 本以上のペースで見つかり始めたら本 ADR を supersede する
- 注意: ADR-0011 決定 4 で失効扱いにした DR-Expect (`fallback_rate` / `pass2_turns_*`) は 1 日 1 line に戻ることで旧意味に復帰するが、2026-08-15〜18 の 4 レコードは 2 line 合算のまま残る。次回 `/dr-review` で期間を分けて読む
