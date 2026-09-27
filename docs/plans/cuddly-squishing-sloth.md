# daily-research: レポートを「動向解説 + repo への含意」へ単純化する

## Context

運用者の観測 (2026-08-22): レポートのスタンスがややこしく読みづらい。前提を崩す・反証する
方向ばかりで、改修の積み重ねでプロンプトが複雑化した。

一次資料で確認した根因 — 「外部の事実」を「repo の立場との位置関係の議論」へ変換する圧が
**3 層**に分散して埋まっている:

1. **プロトコル** `prompts/repo-research-protocol.md` — `:7` 目的関数「前提・問い・立場を
   動かす外部の動き」/ `:14` 裏付け禁止 / `:93` Step 3c 反証プレッシャー / `:123` Step 5
   前提挑戦パス (→ 本文に「反例として自問した」が漏れる)
2. **テンプレート** `templates/report-template.md:23,26` — 記述規律 3 (反対材料必須) /
   4 (定点観測の網羅 + 自分の過去主張の「反故」再検証)
3. **config.toml 全 7 line** — `focus` の定型句「前提・問いを動かす状況判断 — … / 反証」、
   `scoring_criteria` 「影響度 45: 裏付けの追加は影響ではない」「反証性・前進性 30」が
   逐語コピー (`config.toml:40-42,59-61,…,174-176`)、`general.goal` (`:186`) も同文。
   `line-brief` (`dr_pipeline.py:272-278`) が weight 付き文字列として毎朝注入する。
   weight は誰も集計していない (ADR-0010 が Likert を廃した後の残骸)

実例: `2026-08-22_aap_accountability-aggregation-not-distribution.md` (約 7,000 字)。
「これは反証ではない。効くのは別の場所だ……留保した問いが別の論理で埋まっていた」型の
二重否定、主題と無関係な中国標準 / Ohio 法案 / Colorado 規則の定点観測ダンプ (`:154-174`)。
なお `edge` line の focus (`config.toml:165`, ADR-0013 2026-08-20) は既に「反証を repo の
再審の主題にしない」と個別に押し返していた — 同じ症状への対症療法。今回は根を全 line で抜く。

ADR-0008/0009 (2026-08-04/05) の前提「corroboration failure が最大リスク」は supersede:
実害は逆方向 (反証過多で読めない) に出た。ADR-0010 (2026-08-13) の `theme_rank` 評価計画も
supersede。

## 決定事項 (grill-me 2026-08-22)

| 論点 | 決定 |
|---|---|
| 目的関数 | **動向の解説 + repo への含意**。主語は外部の出来事。「何が起きたか → なぜ重要か → この repo にどう使えるか」 |
| 裏付けリスク | 裏付け禁止・反証義務・前提挑戦パスを全部撤去。残すのは「一次ソースで確認した事実と書き手の解釈を分けて書く」1 行 |
| 定点観測 | Step 2 diff パスと `watched-sources.md` / `playbook.md` 更新は維持 (テーマ発見の入力)。本文への網羅記述義務は外す。「変化なし」列挙・過去主張の反故検証は書かない |
| テーマ選別 | 候補 2〜3 → 3 問 (新規か / 一次ソースに届くか / repo のどこに使えるか固有名詞で言えるか)。反証プレッシャー・self-deepen・verdict 廃止。**`theme_rank` 廃止** |
| criteria | `scoring_criteria` を config から削除、`line-brief` の描画コードも削除。判断基準はプロトコルの 3 問に一本化。line 固有の関心は `focus` だけ |
| 構造・長さ | 推奨 4 節骨格「結論 (3〜5 文) → 何が起きたか → 背景 (初見向け、短く) → この repo への含意」+ 固定 2 節 (機会メモ / ソース)。**約 3,000 字上限** (目安、lint しない)。骨格見出しは ctl-016 対象外 |
| 含意の範囲 | 使い道 (どの ADR / task / 問いにどう使えるか) は平文で書いてよい。承認要求・「すべき」・手順列挙は禁止 (ADR-0009 の禁止を承認要求に絞って維持) |
| 改修方式 | プロトコルとテンプレートは白紙から短く書き直す (目標 80〜100 行)。機構との配線は移す。呼2 clarity プロトコルは `theme_rank` 文言の削除以外そのまま |
| 成功基準 | 切替後 7 日分 (約 14 本) を運用者が読み「最後まで読めた / repo に使えたものがあった」を主観判定 — **2026-08-30**。字数だけ metrics に残す |

## 変更ファイル

### 1. `prompts/repo-research-protocol.md` — 白紙から書き直し (Write)

構成 (80〜100 行):
- **役割と目的関数**: 「この repo の運用者に、外部の動向を解説し、repo にどう使えるかを届ける」。
  読者は運用者一人、ノートは読み物。発見ノルマなし (「大きな動きなし」の日は短く書く)
- **大原則** (機構的なものだけ移す): repo read-only / doctrine 尊重 / Bash 不可 / 鮮度
  (全 claim に as-of、機会メモに失効日) / 日本語散文 / **事実と解釈の分離** (一次ソースで
  確認した事実と、書き手の解釈・含意を区別して書く — 唯一残す認識規律)
- **手順**:
  - Step 1 文脈読込 (現行 `:46-58` を移す)
  - Step 2 diff パス (現行 `:60-69` を移す。ただし「レポート本文の材料」文言は
    「テーマ候補の入力」へ。失効した機会の再検証は state 更新のためだけに行う)
  - Step 3 テーマ選択: 候補 2〜3 件 + 探索 quota 1 回 → 3 問 (新規か / 一次到達か /
    repo のどこに使えるか) で 1 件選ぶ。verdict なし
  - Step 4 リサーチ (現行 `:112-121`: 日英検索 / 一次 WebFetch / citation ゲート /
    自己汚染ガード — そのまま)
  - Step 5 執筆: 4 節骨格 + 固定 2 節。約 3,000 字目安。承認要求・手順・「すべき」禁止。
    含意は「どの ADR / task / open question にどう使えるか」を固有名詞で
  - Step 6 state 更新 (現行 `:152-160` そのまま)
  - 完了報告: 現行 `:166-175` から `Theme rank` 行を削除、`Expired/re-verified` 行は削除、
    `Length (chars)` 行を追加 (metrics 用ではなく目視用)
- **書かない**: Step 3c / Step 5 前提挑戦パス / 裏付け禁止の段落 / PseudoBench 根拠の段落

### 2. `templates/report-template.md` — 書き直し (Write)

- frontmatter から `theme_rank` 行を削除 (他キーは維持: date / category / tags / topic /
  sources / actionable)
- 記述規律を 3 点に: (1) 冒頭に結論 (2) 初見読者向けの背景を短く (3) 全 claim に as-of、
  事実と解釈を分ける。規律 3 反対材料・規律 4 定点観測は削除
- 推奨骨格 4 見出しを「推奨 (自由に変えてよい)」として例示。末尾固定 2 節
  (`## 機会メモ` / `## ソース`) は現行どおり — **ctl-016 の `ARTICLE_SECTIONS`
  (`dr_pipeline.py:589-591`) と `## ソース` hard 判定 (`:617`) は無変更**

### 3. `prompts/clarity-review-protocol.md` — 1 箇所 Edit

`:39` の「(`theme_rank` 含む)」を削除。他は無変更。

### 4. `config.toml` (private) と `config.example.toml` — Edit

- 全 7 line の `scoring_criteria` 配列を削除
- `focus` を書き換え: 定型句「外部環境監視と、前提・問いを動かす状況判断 — … / 反証」を
  「外部動向の解説と repo への含意」の語に。line 固有の関心 (AKC: 6 phase cycle …、
  AAP: 規制の発効日・パブコメ …、edge: 3 本柱 …) は**そのまま残す**。edge の
  「反対材料・反証は…主題にしない」文は根が消えるので削除、「有名事例の再確認は成果では
  ない」は新規性の表現として残す
- `sources` 内の「文献は手か反証になる場合のみ」(example `:40` 相当) を「repo に使える
  場合のみ」へ
- `general.goal` (`config.toml:186`, example `:57`) を新目的関数に合わせる
- `config.toml.bak` 等の退避は不要 (gitignore だが git 管理外 → 編集前に
  `config.toml.pre-0014` として scratchpad にコピーを置く)

### 5. `scripts/lib/dr_pipeline.py` — Edit

- `cmd_line_brief` (`:272-278`) の `scoring_criteria` 描画ブロックを削除、`:250` コメントから
  「判断基準」を外す
- `cmd_report_lint`: 本文字数を lint 出力 JSON に含めているか確認し (`:568-643`、
  soft 判定で 1500 字下限を見ている)、`body_chars` が metrics に残るようにする
  (既に出しているなら無変更)。**3,000 字上限の lint は追加しない**

### 6. `scripts/daily-research.sh` — コメント 1 行

`:192` 「(focus / sources / 判断基準 / context_files / self_signals)」から「判断基準」を外す。
ロジック変更なし。

### 7. `.claude/skills/dr-review/SKILL.md` — Edit

- `:46-49` の `theme_rank` 分布集計と判定基準 (A 週 1 本 / 甘さドリフト) を削除
- 代わりに「本文字数の推移 (metrics / lint 出力)」と「主観判定 2026-08-30」を書く
- `:39` の `report-lint ... graph.jsonld` 第 4 引数は旧シグネチャの残骸 — ついでに削除

### 8. テスト — Edit

- `tests/test-e2e-mock.bats:334` — `theme_rank` の注入検査を `## 機会メモ` 等の
  新テンプレート文言へ
- `tests/test-daily-research.bats:95-98` — テスト名と grep を「background explanation and
  fixed tail sections」へ (反対材料 grep を削除)
- `tests/dr_pipeline_test.py` の lint テスト (`:685-716`) は ARTICLE_SECTIONS 無変更なので
  そのまま通る想定。line-brief のテストがあれば `scoring_criteria` 期待を削除

### 9. ドキュメント — Edit

- `CLAUDE.md` (`:100`, `:192` 周辺): run 構造の「テーマ選別 (T1〜T6 → 反証プレッシャー →
  theme_rank)」「前提挑戦パス」「裏付け禁止」の記述を新構造へ。「目的関数 (ADR-0009)」
  段落を ADR-0014 参照に
- `README.md` (`:21,30,45`) / `docs/RUNBOOK.md:68` / `docs/RUNBOOK.ja.md:68` /
  `docs/CONTRIB.md:25`: `theme_rank` 言及を削除
- `docs/adr/0010-rotation-and-two-tier-eval.md` / `0013-edge-daily-line.md:39`:
  削除せず、日付付き注記「2026-08-22 ADR-0014 により theme_rank 廃止」を追記 (akc-cycle 規約)

### 10. `docs/adr/0014-*.md` — 新規 (skill: `adr-writer`)

ADR テスト: (1) 3 ADR の supersede で元に戻しにくい (2) 「なぜ反証義務を外したか」は
将来読者に非自明 (3) 読みやすさ vs corroboration 防御の実トレードオフ → 3 条件成立。
内容: Context = 上記根因と実例、Decision = 決定事項表、Review-when = 2026-08-30 主観判定 /
「裏付けだけのレポートが 1 週間に 3 本以上出たら事実・解釈分離規律を強める」、
Supersedes = ADR-0008 Decision の目的関数 / ADR-0009 の提案禁止範囲 / ADR-0010 の
Step 3 チェックリストと theme_rank 評価。index `docs/adr/README.md` に追記。

### 順序

1 → 2 → 3 (プロンプト層) → 4 → 5 → 6 (config と機構) → 8 (テスト) → 7 → 9 → 10 (消費側と doc)。
commit は 1 つ、`DR-Expect: lint_hard_count == 0` trailer を付ける (ADR-0006 規約)。

## Verification

1. `bats tests/` と `.venv/bin/python -m pytest` が全通
2. `python3 scripts/lib/dr_pipeline.py line-brief config.toml aap` の出力に
   「判断基準」「反証」「動かす」が含まれない (全 7 line で grep)
3. `grep -rn "theme_rank\|反証プレッシャー\|前提挑戦" prompts templates scripts tests docs CLAUDE.md README*.md .claude/skills` が
   ADR-0010/0013 の注記と ADR-0014 以外でヒットしない
4. `.claude/verify.sh` があれば実行、無ければ 1〜3 で代替
5. E2E は翌朝 2026-08-23 05:00 の launchd 実行で確認: vault の `2026-08-23_edge_*` と輪番 line の
   ノートが 4 節骨格・約 3,000 字以内・`theme_rank` なしで出ているか。
   `DR_ONLY_TRACK=aap ./scripts/daily-research.sh` を別ターミナルで先に 1 本流してもよい
   (Claude Code セッション内からは実行不可)
6. 2026-08-30 に 7 日分を読んで主観判定 → ADR-0014 の Review-when を閉じる

## Non-goals

- orchestrator のロジック (rotation / daily line / ゲート ctl-015/016 / metrics) は不変
- 呼2 clarity プロトコルの品質バーは広げない
- 3,000 字の機械 lint は作らない (Goodhart 回避)
- watched-sources / playbook の state 機構は維持
