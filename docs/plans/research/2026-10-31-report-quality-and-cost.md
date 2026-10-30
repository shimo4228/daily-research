# 調査記録: レポートの質とコスト（2026-10-31）

plan の前の内部調査。問いは 2 つ — (1) 問いの選定がずれる・同じ題材に戻るのはなぜか、(2) 1 line あたりの
費用はどこに出ているか。数値は特記がない限り 2026-10-31 時点の実測。判断は grill-me（同日、運用者）で
決まり、plan が正本。この記録は根拠の束で、plan から参照される。

## 1. 費用の内訳（呼1 が 85%、その 3 割は呼び出しの土台）

- 支出台帳 `state/api-spend.jsonl`（2026-10-30〜31、live 6 line）: 呼1 $1.41〜1.65、呼2 $0.20〜0.26。
  1 日 3 本で約 $5.3、月換算 ≈ $160。
- 呼1 の usage（`logs/2026-10-3{0,1}.log` の result JSON）: cache 書き込み 89k〜137k token、cache 読み
  1.79M〜2.84M token、出力 18k〜26k token、33〜58 ターン。
- 単価は `docs/RUNBOOK.md:354` の 2026-10-29 定価（Opus 5.5 入力 $4 / 出力 $20 / cache 読み $0.20 per
  MTok）。cache 書き込みは入力の 1.25 倍 = $5 で、akc 呼1（2026-10-31）の実費 $1.65 と内訳
  134,147×5 + 2,277,324×0.2 + 22,689×20（per M）+ 検索 ≈ $1.62 が一致する。
  → 呼1 の内訳は cache 書き込み ≈ 40% / cache 読み ≈ 28% / 出力 ≈ 28% / 検索 ≈ 3%。
- 呼び出しの土台（probe: CLI 2.1.314、`claude -p "OKとだけ答えて" --model haiku --max-turns 1`）:

  | 起動条件 | cache 書き込み + 読み |
  |---|---|
  | cwd = 対象 repo（akc）、safe-mode なし（呼1 と同じ） | 64,470 + 0 |
  | 同、`--safe-mode` | 28,778 + 0 |
  | cwd = daily-research、safe-mode なし（呼2 と同じ） | 47,256 + 21,936 |
  | 同、`--safe-mode` | 6,313 + 22,469 |
  | 同、`--safe-mode --tools "Read,WebFetch,Edit"` | 5,704 + 0 |

  差の内訳: `~/.claude` のハーネス（CLAUDE.md・rules・skill 一覧・plugin）と cwd の CLAUDE.md で約 3.6〜4
  万 token、使わない組み込みツールの定義で約 2.3 万 token。safe-mode の合計が両 cwd で同値なので、
  **safe-mode は cwd（対象 repo）の CLAUDE.md も落とす**。API 課金への切替（commit 44a61a5）は支払い元を
  変えただけで、起動するのは今も Claude Code CLI なので土台は残る。
- 推定: 土台を約 6 万 token 削ると、呼1 は 1 本 $0.4〜0.7、呼2 は 1 本 $0.1〜0.2 下がる。ターン数と
  リクエスト数の対応が result JSON から確定できないため幅がある。実 run の支出台帳で確かめる。

## 2. CLI フラグ（一次情報 = `claude --help`、2.1.314、2026-10-31）

- `--safe-mode`: CLAUDE.md・skills・installed plugins・hooks・MCP servers・custom commands and agents・
  output styles・workflows などを無効化。「Auth, model selection, built-in tools and plugins, and
  permissions work normally」。ADR-0018 の 2026-09-21 probe（safe mode は permissions を外さない）と一致。
- `--tools <tools...>`: 組み込みツールの集合を指定（`""` で全無効、`default` で既定集合）。
- `--restricted`（今回は使わない）: コード実行系ツールと WebFetch を外し、user / project / local の
  settings ファイルを無視する。境界の書き方を変える選択肢なので別 plan の候補。

## 3. 選定がずれる・繰り返す仕組み

- 終わり方の分布（`metrics.jsonl`、source = live、2026-09-14 以降 11 日 30 run）: article 25 / brief 5 /
  quiet 0 / hold 0。材料が薄い日にも何か書いている。
- brief の「開いた問い」はモデルが毎 run 書き足して閉じる（`prompts/repo-research-protocol.md:173`）。
  選定前に読む 4 入力の 1 つ（同 :39）。aap の 2026-10-31 記事（Linux カーネルの Assisted-by 撤去）は、
  2026-08-22 から開いていた問いの判定 source が来たので閉じに行った回で、運用者は「少しずれている」と評価。
- 選定基準は「答えが分かっていない度合い」第一、「一次ソースに届く見込み」第二で、repo での使い道は
  ゲートにしない（同 :73）。運用者のいまの関心が選定に入る入口が無い。
- 構成の歴史（`docs/adr/`）: track 制（2026-02〜07）は固定 domain の飽和で tech track を廃止
  （2026-05-27）。自由探索は cluster 反発で関心から離れ ADR-0007 で廃止（廃止理由は広さでなく反発の機構）。
  per-repo（ADR-0008、2026-08-04）は狭い領域を週 2〜3 回掘るので題材の到着速度を上回った。
  運用者の体感では 5〜6 月（track 制の tech / ai_dev / personal）が最も鋭かった。

## 4. state の肥大（run ごとの記帳）

| ファイル | 大きさ（line ごと） | 読み手 |
|---|---|---|
| `playbook.md` | 45〜76 KB（jev は 3 KB） | なし（scripts・`dr_pipeline.py`・dr-review を grep。追記のための Read だけ） |
| `watched-sources.md` | 12〜171 KB（edge 171 KB、80 行の大半が事例の経過メモ） | 呼1 Step 2.1（毎 run 全 source 巡回 + last-attempt / last-seen 記帳） |
| `brief.md` | 4〜8 KB | 呼1 Step 1（開いた問いを含む） |
| `pending.md` | 1〜6 KB | 呼1 Step 1、機会メモの正本 |
| `past_topics.json` | 595 件・約 1.04 MB（全 line 共有） | `dr_pipeline.py past-themes`（:334）。追記はモデルが Read → 追加 → Write（protocol :183） |

文体規律 5（育った造語を未定義で使わない、protocol :146）は playbook 由来の内部語が記事へ漏れたことへの
規則で、playbook が品質にも負に効いていた痕跡。

## 5. プロトコルの増量

`prompts/repo-research-protocol.md` のバイト数: 8,750（82588cb、2026-08-22、ADR-0014 の単純化）→
10,615（56b0bfb、08-27、文体規律）→ 16,880（a51407d、09-14、ADR-0017）→ 17,063（393b51c）。
ecosystem 版は 22,012 B。本文の減量は今回の plan の対象外（運用者判断）。

## 6. 採用の基準値（`adoption_backtest.py`）

定義は同スクリプトの docstring が正本。対象は 2026-08-04〜10-31 のノート、21 日窓。

| line | notes | adopted | re-cited |
|---|--:|--:|--:|
| aap | 19 | 0 | 5 |
| akc | 21 | 3 | 10 |
| ans | 16 | 1 | 0 |
| authorship | 19 | 0 | 0 |
| contemplative | 19 | 4 | 2 |
| desire | 14 | 5 | 2 |
| edge | 25 | 12 | 2 |
| jev | 2 | 0 | 1 |
| discovery（ADR-0016 の 1 週間） | 7 | 0 | 0 |
| 全体 | 142 | 25（18%） | 22（15%） |

- per-repo の 7 line だけ（133 本）: 採用 19%、引き直し 16%。窓なしでは全体の採用 32 本（23%）。
  authorship は窓なしで 6 本、21 日窓で 0 本（採用が 21 日より後）。
- 運用者の評価と一致する点: 「少しずれている」とした aap と「外してよい」とした jev はいずれも採用 0。
- 精度: 率の 95% 信頼区間の半幅 ≈ 1/√n。n = 42（per-repo 1 本/日で 6 週）で ±15 pt なので、19% →
  15% や 16% → 10% の差は判定できない。引き直しはノート当日に判定できる（遅れなし）、採用は 21 日遅れる。

## 7. 文書の重複

構成の説明が CLAUDE.md（26.6 KB）・README 英日（19.4 / 23.7 KB）・RUNBOOK 英日（19.5 / 22.7 KB）・
CONTRIB 英日（18.2 / 20.5 KB）・llms-full.txt（42.2 KB）の 8 か所にある。すでに食い違いがある:
`CLAUDE.md:3` と `CLAUDE.md:280` は 1 日 3 本、`config.toml` は `lines_per_day = 2`（`CLAUDE.md:293` も
2 本）。費用見積もり `CLAUDE.md:292` / `docs/RUNBOOK.md:354` は 1 本 $2.4〜2.9、実測は $1.6〜1.9。
凍結アーカイブ `graph.jsonld`（339 KB、ADR-0008 で増分停止）と `docs/graph-schema.md` が残る。

## 8. 削除候補の読み手（棚卸しの注意）

`dr_pipeline.py` の `metrics-backfill` と `wiki-quality-scan` は scripts から呼ばれないが、
`.claude/skills/dr-review/SKILL.md:23` と `:54` が使う。**未使用ではない**。削除候補は読み手を
`.claude/skills/` まで含めて棚卸ししてから消す。

## 9. jev-research-pipeline（jrp）との比較

jrp の README「Why jrp」: Opus agent（2026-09-15〜22）は 1 朝 107〜242 ターン・$8〜15、jrp
（2026-10-03〜07）は $1.1〜1.5。安さの理由は「ターンが無い」こと — 候補はコードが集め、関連判定は
Jev（選択式で確率だけ返すモデル）、LLM は本文だけ書く。情報源は論文と repo に固定で、daily-research の
強み（LWN・issue・エッセイ・Octoverse のような Web 全体の発見）は持たない。jrp のノートの「読む価値」
欄には 106 本中 32 か所に印があった。jrp は launchd に登録されておらず、API key を使うのは
daily-research だけ。

## 10. 作業環境の前提

- repo に `.claude/verify.sh` が無い（global の規約では verify-bootstrap で作ってから実装する）。
- 作業ツリーに前セッションの未コミット変更がある（`tests/test_helper.bash` の新設と bats 2 本の書き換え、
  CLAUDE.md / CONTRIB への 1 行追記）。この plan の変更と混ぜない。
