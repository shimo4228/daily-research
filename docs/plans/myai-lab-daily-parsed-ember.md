# Plan: `jev` — Jev エコシステムを毎日観測する daily line

## Context

誕生直後の Jev エコシステム (Jev / System One / typed probabilistic judgment を制御面に置く基盤・OSS・
plugin・近接実装) を毎朝観測する line を足す。既存 7 line と輪番は不変、`jev` は輪番外の `daily = true`。

現行コードで確認した事実 (2026-09-21):

- `daily = true` 機構は生きている: `dr_pipeline.py:_track_rows` / `cmd_rotation_pick` が非 daily 行だけで
  window を組み、daily 行を config 記述順で末尾に足す。`lines_per_day` の検証も daily と独立。→ **再利用**
- **repo なし line は現状走れない**: `_track_rows` は `[[tracks.x.repos]]` が無い track を 0 行にする
  (黙って消える)。shell は `cd "$TARGET_REPO"` 前提、プロトコル・既定テンプレート・LINE_PROMPT は
  「この research repo」前提の文言。ADR-0008 は「復活には別の実行形の設計が必要」と明記
- line 名・line 数の hard-code はコードに無い (docs の「7 line」だけ)。gate / lint / metrics / past-themes /
  呼2 は line 非依存でそのまま使える
- `claude -p` は cwd に関係なく `~/.claude/CLAUDE.md` + rules を自動ロードする。公式 docs / `claude --help`
  (as-of 2026-09-21) に `--safe-mode` (CLAUDE.md・skills・plugins・hooks・MCP を無効化、permissions と
  built-in tools は通常動作) がある

## 設計 (最小の config 駆動拡張)

**新しい track key `mode`** — `"repo"` (既定、省略可) | `"ecosystem"`。line 名での分岐は入れない。

| 層 | `mode = "ecosystem"` の挙動 |
|---|---|
| schema (`_load_tracks`) | `mode` は enum 検証。ecosystem で `repos` / `context_files` があれば ValueError (repo 文脈を**要求できない**ことを schema で強制) |
| 行構築 (`_track_rows`) | `track \t track \t ""` を 1 行出す (3 列 TSV 形は不変。daily フラグは既存どおり) |
| cwd | `state/<line>/` (line-local state だけが手元の文脈。Glob/Grep の既定範囲もここ) |
| プロトコル | `prompts/ecosystem-research-protocol.md` (新規) |
| harness 隔離 | 呼1 に `--safe-mode` を足す — **下の probe で効くと確認できた場合のみ** |
| line-brief | 先頭に `- mode: ecosystem (接地 repo なし)` を 1 行。repo line の出力は byte 不変 |
| LINE_PROMPT | 冒頭ラベルと「作業ディレクトリ =」の 1 行だけを mode で差し替え。repo line の文字列は不変 |

既存 `repo-research-protocol.md` と `report-template.md` は**触らない** (既存 line への文言漏れゼロを
ファイル単位で保証)。共有契約 (receipt 形式・根拠ファイル表・固定 2 節・4 状態) の drift は、静的テストを
両プロトコルに同じ assertion で当てて止める。

### 新プロトコル `prompts/ecosystem-research-protocol.md` (Jev 固有語は書かない — 固有性は config と state に置く)

既存プロトコルの Step 4 / 4b / 5.5 / 完了報告は同形で持つ。差分:

- 目的関数: 観測対象は**エコシステムの変化そのもの**。運用者の harness・研究 repo への適用可能性は選定理由にも
  本文の着地にも使わない。repo / `~/.claude` / 他 line の state を読まない (大原則に明記)
- Step 2 を 2 経路に分けて**両方必須**: (A) watchlist 差分 — 各エントリの release / commit / issue /
  discussion を前回比で確認、last-attempt と last-seen を分離 / (B) 未知探索 — watchlist に無い名前・repo・
  設計語彙・近接実装を 2〜4 query で。(B) で既知候補に当たったら (A) の差分判定へ回し、新発見に数えない。
  完了報告に「A: 差分 n/m、B: 新規候補 k」を出す
- Step 3 の dedup は「前回報告後の変化」: 再掲載できる変化 (初の動くコード / release・重要 commit /
  benchmark・実測・実利用 / アーキテクチャ変更 / 停止・archive・削除 / 主張の支持・否定) と、不可
  (同じ README・demo・主張の言い換え) を列挙。`question` / `answer_scope` の問い単位判定は既存どおり
- 4 状態の目安: article = 新基盤・重要 OSS・実測を伴う動き / brief = 小さい release・plugin・実験・issue /
  quiet = 意味のある変化なし (再包装しない) / hold = 有望だが一次ソース・動く実装を未確認
- Step 3b は無い。Step 5 の流れ: 何が公開・更新されたか → 実装の実在と依存関係での実使用 → 単なる
  router/judge/plugin か新しい制御基盤か → 実測 (速度・価格・精度・呼び出し削減) → 不確実性・誤判定・
  fallback → いま試せるか → 確認済み事実と将来性の推論の分離。固定見出しは足さない
- 一次ソース優先順、awesome list は入口であって採用根拠にしない (canonical source を直接確認)、
  公開日と出来事の日付を分ける
- Step 6 `watched-sources.md` の表形式を定義 (新しい永続形式・parser は作らない — model が読む markdown):
  `| 名前 | canonical URL | 種別 | 初出日 | last-attempt | last-seen | 最後に報告した意味のある変化 | 状態 |`
  状態 = active / watch / hold / stalled / archived。削除せず状態で表す

### テンプレート `templates/report-template-ecosystem.md` (新規)

既定テンプレートと同じ frontmatter (`kind` / `question`) + 固定 2 節 (`## 機会メモ` / `## ソース`)、
本文固定見出しなし。repo 前提の 2 文 (「この repo との接点」「自己紹介は 2 文まで」) を上の Step 5 の流れに
置換しただけ。ctl-016 (`ARTICLE_SECTIONS`) は変更不要。

## 変更ファイル

- `scripts/lib/dr_pipeline.py` — `_load_tracks` (mode 検証)、`_track_rows` (ecosystem 行)、`cmd_line_brief`
  (mode 行)、`_track_repos` の死んだ docstring「= 自由探索ライン」を現行事実に直す
- `scripts/daily-research.sh` — ループ冒頭で `config-get tracks.$TRACK.mode repo` (既存 subcommand、3 階層
  対応済み) → `LINE_CWD` / `LINE_PROTOCOL` / `LINE_EXTRA_FLAGS` / prompt の 2 行を決める。
  `[ ! -d "$LINE_CWD" ]` と `cd "$LINE_CWD"` に一般化 (`mkdir -p "$STATE_DIR/runs"` が先にあるので
  ecosystem は常に存在)。allowedTools / deny / gate / 呼2 は不変
- `prompts/ecosystem-research-protocol.md`、`templates/report-template-ecosystem.md` — 新規
- `config.toml` (private) と `config.example.toml` — `[tracks.jev]` (`mode = "ecosystem"`, `daily = true`,
  `template`, `name`, `focus`, `sources`; repos / context_files なし)。example は同じ形をコメント付きの
  `example_ecosystem_line` として載せ、個人パスなし。`[user_profile].goal` の「7 つ」も同期
- `state/jev/{brief,pending,watched-sources,playbook}.md` + `runs/` — 初期値 (gitignored)。watchlist の seed は
  **実装時に WebFetch で canonical URL を確認できたものだけ** (TypeSafe/Jev 公式サイト・docs・GitHub org・
  cookbook・awesome list・registry)。記憶から URL を書かない。確認できなければ空表 + 探索起点は config の
  `sources` に任せる
- テスト (下記)、`tests/fixtures/config-ecosystem.toml` 新規
- docs: `CLAUDE.md` (冒頭・Directory・設計方針・Status・コスト)、`README.md` / `README.ja.md` (line 数・
  daily 行・config 例)、`llms.txt` / `llms-full.txt` (「Seven lines」「no line is configured as daily」)、
  `docs/RUNBOOK(.ja).md` (本数・所要時間・コスト)、`docs/CONTRIB(.ja).md` (track key 表に `mode`)、`SKILL.md` は
  該当記述があれば
- `docs/adr/0018-ecosystem-mode-daily-jev-line.md` 新規 + `docs/adr/README.md` index。ADR-0008 (repo なし line は
  別実行形が必要 → 本 ADR がその実行形) と ADR-0017 (daily line 0 本 / cost 閾値) に `> **注記（2026-09-21,
  ADR-0018）**`。skill: `adr-writer` の手順 + `adr-reviewer` を通す

### ADR-0018 に書く判断 (承認対象)

1. `mode = "ecosystem"` の導入と、ADR-0007 で死んだ「自由探索 line」との違い (固定主題 + watchlist 差分 +
   変化単位 dedup + quiet を正常系とする — 飽和・関心乖離への対処)
2. `jev` を daily にする。実行周期 = 毎朝、輪番 3 本の**後**に 1 本 (計 4 本/日)
3. **コスト・時間**: +$4.5〜6/日 → 1 日 $17〜21、最悪完了 05:00 + 約 240 分。ADR-0017 Review-when の
   `total_cost_mean > 18` は 3 本前提の天井なので、**4 本前提の 24 ($18 × 4/3) に再基準化**する注記を提案
4. Review-when: jev の `quiet_rate` が 14 日で 0.7 超 (生態系が毎日追うほど動いていない → 輪番か週次へ) /
   同一エントリの再掲載が続く / エコシステムが成熟して「初期観測」の前提が消える

## テスト (TDD: 先に赤)

`tests/dr_pipeline_test.py`
- ecosystem + daily の line が全日付で選ばれ、window の**後ろ**に付く / 7 rotating + jev で 7 日間の window が
  `K3_ORDER` と完全一致 (既存の順序・`lines_per_day` の意味が不変) / `tracks` の行形
- `mode` enum 違反、ecosystem + `repos`、ecosystem + `context_files` が ValueError
- `line-brief`: mode 行あり・`選定後に読む候補` 節なし・focus / sources あり。repo line の出力は従来と同一
- `template-path` が ecosystem テンプレートを返す

`tests/test-e2e-mock.bats` (mock claude が `*ecosystem-research-protocol.md` も呼1 と認識し、`pwd` と引数を記録)
- ecosystem daily line が repo dir **無し**で走り、cwd = `state/<line>`、protocol = ecosystem、(採用時) `--safe-mode`
  あり。repo line 側は cwd = target_repo・旧 protocol・`--safe-mode` なし
- article / brief / quiet / hold の 4 状態が既存 gate を通る (既存 `.state_<track>` seam を再利用)
- LINE_PROMPT に「research repo」文言が出ない

`tests/test-daily-research.bats`
- 固定 2 節・frontmatter・receipt schema・4 状態の静的 assertion を ecosystem プロトコル / テンプレートにも適用
- `config.example.toml` が `tracks` / `rotation-pick` / `line-brief` を通り、ecosystem 例が 1 行出る
- ecosystem プロトコルに `Step 3b` / `repo の doctrine` が無い、既存プロトコルに `watchlist` 等の新語が無い

## 検証

1. **`--safe-mode` probe (承認が要る唯一の実呼び出し)**: `claude -p "<ロード済み instruction file を列挙>" --model haiku
   --max-turns 1 [--safe-mode] < /dev/null` を有無 2 回。`-p` + `--append-system-prompt-file` と両立し、
   `~/.claude/CLAUDE.md` が消えることを確認。数セント相当。**効かなければ採用せず doctrine + cwd の 2 層に留め、
   残る制約として報告**
2. `bats tests/` / `.venv/bin/python -m pytest` (coverage 80% 以上) / `ruff check` / `.claude/verify.sh` があれば
   それ / `git diff --check` / `git status --short`
3. 実 config の dry 確認 (API 呼び出しなし): `dr_pipeline.py rotation-pick config.toml <7 日分>` で既存 window が
   変更前と同一 + 末尾に jev、`line-brief config.toml jev`
4. 別プロセスの reviewer (code-reviewer + security-reviewer: `--safe-mode` / cwd 変更は permission 境界に触れる)

本番 run・vault 書き込み・commit・push・launchd 再登録はしない。

## 残る制約 (実装後も残るもの)

- 初回の実 run までプロトコルの質は未検証 (mock は配線だけを見る)。翌朝 05:00 の run が最初の実測
- read の permission 層は無い: ecosystem line が他 path を Read しないのは doctrine + cwd (+ safe-mode) による
- watchlist は model が保守する markdown — 形式崩れは機械検査されない (parser を増やさない判断の対価)
