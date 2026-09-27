# daily-research: 提案型ノート → 自由形式の解説レポートへ転換し、朝の Slack 承認ブリーフを廃止する

## Context

ADR-0008 (2026-08-04) で毎朝のリサーチは「今すぐ実行できる作業の提案」を作る設計になり、
7:00 に morning-brief.sh が「実装プラン承認リクエスト (N 件)」を Slack へ送るようになった。
初の全 line 走行 (2026-08-05、5 line) で運用者が観測した問題は 2 つ:

1. **承認キュー化**: 全ノートが作業提案で始まり、毎朝 5 件前後の「返事待ち todo」として
   Slack に着弾する — 消火感
2. **前段の説明不足で各論が読めない**: ノートが専門用語 (例:「weight-consolidation 批判」
   「text-level distillation」) を説明なしに使い、いきなり各論に入る。そのリサーチが
   そもそも何の論点か・登場する概念は何かという背景説明が無いため、唯一の読者である
   運用者が内容を理解できない

方針: **repo の中で実行するリサーチのエンジン (per-repo cwd 実行・定点観測・出典の
実アクセス確認・反対材料の義務・重複防止) は無変更**のまま、出力を「承認を求める
作業指示書」から「**単体で読んで理解できる自由形式の解説レポート**」に変える。

grill-me 面談 (2026-08-05) で確定した決定:

- リードは提案ではなく状況判断 (読む行為で完結し、返答義務がない)
- **Slack 7:00 ブリーフは完全廃止**。期限見逃しの代替通知も作らない
  (締切はノートを読むときに拾う、と明示的に受容したトレードオフ)
- 期限付き機会だけは軽量 3 行定型 (何を / どこで / 失効日) で末尾に残す
- **レポート本文の形式は自由** — 厳密な節定型を課さない。課すのは下記の必須要素のみ

## 新しいレポートの要件

### 本文 = 自由形式。ただし次の記述規律を課す (プロトコルの文言として)

1. **冒頭に結論**: 今日の外部の動きが repo の主張・問いにどう効くかの総合判断を数文で。
   提案・承認要求は書かない。「変化なし」の日はそれを根拠付きで書く (それも正の成果)
2. **前段の背景解説を必ず置く**: 各論に入る前に、今日の主題がそもそも何の論点か・
   登場する概念・なぜこの repo に関係するかを、**前提知識ゼロの読者向けに数段落で解説**
   する。専門用語は初出時に平易に説明する。例 (今朝の AKC ノートなら):
   「今日の主題は『AI agent が経験から学んだことをどこに保存するか』という論点。
   立場は 2 つ — (1) テキスト保存派: 経験を skill・文書として書き溜める。AKC はこちら。
   (2) 重み保存派: モデル本体のパラメータに焼き込むのが本物の記憶とする立場。
   今日確認した Xu et al. 論文は (2) から (1) を『メモ帳の整理であって専門性の獲得では
   ない』と批判する…」
3. **反対材料を含める**: repo の主張に反する・都合の悪い外部知見を最低 1 件、本文中で
   扱う (AI リサーチが裏付けばかり集める failure mode への対抗策 — ADR-0008 から維持)。
   見つからない日は「反証方向で N 回検索したが無し」と明記
4. 定点観測 (見張っている場所の変化なし/変化あり) の結果はどこかに含める (形式自由)
5. 全 claim に as-of 日付、一次ソース確認済みと二次情報の区別 — 現行規律を維持

### 機械検査できる固定部分は 2 節だけ (ctl-016 を縮退)

- **`## 機会メモ`** (必須節、内容「なし」可): 日付付き締切を持つ機会だけを
  「何を / どこで / 失効日」の 3 行定型で。手順・所要・gate 留意の重定型は廃止
- **`## ソース`** (必須節): 最低 5 件、全 URL をその run 内で実アクセス確認済み

frontmatter は現行維持。`actionable:` はフィールド名を保ち、意味を「機会メモ件数」に
変更 (metrics のスキーマ churn 回避)。

## 変更するファイル

1. **`templates/report-template.md`** — 上記要件に書き換え: frontmatter + 記述規律の
   説明 + 自由本文の placeholder + 固定 2 節 (機会メモ / ソース)
2. **`prompts/repo-research-protocol.md`** — 目的関数を「実行可能な手の発見」→
   「repo の前提・問いを動かす状況判断を、**前提知識ゼロで読める解説記事**として届ける」
   に書き換え。背景解説・用語説明の規律を追加。手数ノルマ関連の文言を除去。
   diff-first / citation ゲート / 反対材料 / 自己汚染ガード / repo read-only は無変更
3. **`scripts/lib/dr_pipeline.py`** — report-lint (ctl-016) の必須節リスト
   `ARTICLE_SECTIONS` を「機会メモ / ソース」の 2 節に縮退
4. **morning-brief の廃止** — `scripts/morning-brief.sh` と
   `com.example.daily-research-brief.plist` を削除 (git history で復元可能)。
   morning-brief 参照の bats テストを削除 (`grep -rl morning-brief tests/` で特定)。
   運用手順 (実装後にユーザー環境で実行):
   `launchctl unload ~/Library/LaunchAgents/com.daily-research-brief.plist` →
   symlink と local plist を削除
5. **config 文言同期** (gitignored) — `config.toml` 各 track の `focus`「実行可能な手の
   発見」→「外部環境監視と状況判断」系へ (5 line 分) + `user_profile.goal`。
   `config.example.toml` も同趣旨に
6. **doc sync + ADR-0009 新設** — `CLAUDE.md` (冒頭・Directory Structure・Conventions・
   Status)、`docs/RUNBOOK.md` / `RUNBOOK.ja.md` の brief 記述除去。ADR-0009
   (adr-writer agent 使用):「解説レポートへの転換と承認ブリーフの廃止」— ADR-0008 の
   Decision 2 (目的関数) と 6 (承認ブリーフ) を修正、1/3/4/5/7 は維持と明記

## 変更しないもの (non-goals)

- `scripts/daily-research.sh` のオーケストレーション (5:00 実行・allowedTools 制限・
  state 層・リトライ・レポート存在ゲート ctl-015)
- 蓄積層 (LLM-wiki への取り込み)、metrics.jsonl のレコード形、/dr-review、line 構成 (5 line)

## Verification

1. `bats tests/` + `.venv/bin/python -m pytest` (report-lint のテスト fixture を新要件に更新)
2. 新テンプレート準拠のサンプルノートに `dr_pipeline.py report-lint` を当てて pass を確認
3. `launchctl list | grep daily-research` で brief が消え、research (5:00) だけ残ることを確認
4. 翌朝の実 run で: ノートが 5 line 分出る / Slack 通知が来ない / 冒頭が結論、直後に
   背景解説があり、前提知識なしで各論まで読み通せる
5. 成功判定 (初週): 消火感の消滅 + ノートを単体で理解できること (運用者の主観) +
   ctl-016 hard fail ゼロ (機械)
