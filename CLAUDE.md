# daily-research

Claude Code 非対話モード (`claude -p`) + macOS launchd で毎朝 AM 5:00 に自律リサーチを実行するシステム。7 つの研究ライン (line) が 7 つの研究 repo に 1:1 でマッピングされる (`akc` = agent-knowledge-cycle / `contemplative` = contemplative-agent / `aap` = agent-attribution-practice / `authorship` = authorship-strategy / `ans` = attention-not-self / `desire` = desire-frontier / `edge` = edge-frontier。desire / edge 以外は DOI 登録済み)。**rotation + 二層 eval (ADR-0010) + daily line 機構 (ADR-0011、2026-08-20 以降は `edge` が daily = ADR-0013)**: 毎朝、輪番で選ばれた 1 line (と `daily = true` の line があればそれも) が `claude -p` を **cwd = 対象 repo** で実行し (per-repo in-context research, ADR-0008)、repo 自身の運用文脈 (CLAUDE.md / タスク台帳 / open questions / 実施履歴) から「repo に関係する外部の動向」を 1 つ選んで解説し、repo への含意を添える (ADR-0014)。run 内でテーマ候補を複数生成して 3 問 (新規か / 一次到達か / 使い道を言えるか) で選別し、執筆後に fresh-context の clarity 改稿 (呼2) が可読性を仕上げる。出力は**前提知識ゼロで読める自由形式の解説レポート** (ADR-0009) を Obsidian vault へ — 提案・承認要求は書かず、日付付き締切を持つ機会だけを末尾「機会メモ」に記録する。7:00 の Slack 承認ブリーフは廃止済み (ADR-0009)。

## Tech Stack

- Shell script (Bash) — オーケストレーション層
- **Sanctioned runtime ルール**: pip 依存なし。ランタイムは bash + stdlib python3 (>=3.11,
  tomllib 必須) + coreutils `timeout`。JSON/TOML 解析は `scripts/lib/dr_pipeline.py`
  (stdlib のみ: json/tomllib/re) に集約。homebrew `/opt/homebrew/bin/python3` を使う
  (system 3.9.6 は tomllib 不足で不可)
- Claude Code CLI (`claude -p`) — 非対話モード
- TOML — 設定ファイル (`config.toml`)
- launchd — macOS スケジューラ (5:00 research)
- bats (shell) + pytest (python) — テスト。pytest は dev/test 専用 (`.venv`)、
  ランタイムには載らない

## Directory Structure

```
daily-research/
├── scripts/
│   ├── daily-research.sh       # オーケストレータ（輪番 1 line + daily line、各 line 呼1 研究 + 呼2 clarity）
│   ├── lib/                    # sourced ライブラリ + python 解析モジュール
│   │   ├── env.sh              # 環境サニタイズ + PATH
│   │   ├── log.sh              # log() / log_init()（作成時 chmod、30日ローテーション）
│   │   ├── notify.sh           # notify()（osascript ガード）
│   │   ├── lock.sh             # acquire_lock()/release_lock()（mkdir アトミック）
│   │   ├── auth.sh             # real_auth_probe()（実 OAuth probe）
│   │   ├── claude.sh           # run_claude()/classify_exit()（E_AUTH/E_TRANSIENT/E_FATAL）
│   │   └── dr_pipeline.py      # JSON/TOML 解析の単一モジュール（rotation-pick / line-brief /
│   │                           #   past-themes / report-lint / metrics-* / expect-check 等）
│   ├── check-auth.sh           # OAuth トークンの実 probe ヘルスチェック
│   └── pre-commit.sh           # secret / 構文ガード（git pre-commit hook）
├── prompts/
│   ├── repo-research-protocol.md # per-repo リサーチ・プロトコル（品質の中核、ADR-0008。
│   │                             #   Step 3 テーマ選別 = ADR-0010）
│   └── clarity-review-protocol.md # 呼2 fresh-context clarity 改稿プロトコル（ADR-0010）
├── templates/
│   └── report-template.md      # 解説レポートの記述規律 + 固定 2 節（YAML frontmatter 付き）
├── state/                      # line 別 diff-first 状態（watched-sources.md / playbook.md、.gitignore）
├── graph.jsonld                # 旧 concept cluster graph — 凍結アーカイブ（増分停止、ADR-0008）
├── config.toml                 # line=repo マッピング・context_files・self_signals・出力設定（.gitignore）
├── config.example.toml         # config.toml のテンプレート（Git 管理）
├── past_topics.json            # 過去テーマ履歴（.gitignore）
├── logs/                       # 実行ログ（30日でローテーション、.gitignore）
├── tests/                      # bats（daily-research / e2e-mock / lib）+ pytest（dr_pipeline_test.py）+ fixtures/
├── docs/
│   ├── RUNBOOK.md / RUNBOOK.ja.md   # 運用ガイド
│   ├── CONTRIB.md / CONTRIB.ja.md   # 開発ガイド
│   ├── graph-schema.md              # 凍結アーカイブ graph.jsonld のスキーマ（参照用）
│   └── adr/                         # アーキテクチャ決定記録（0001-0014 + README）
├── llms.txt / llms-full.txt    # AI 向けナビゲータ / 自己完結リファレンス
├── SKILL.md                    # Claude Code skill マニフェスト（~/.claude/skills/daily-research として clone 可）
├── metrics.example.jsonl       # metrics.jsonl のレコード形の例（Git 管理）
├── past_topics.example.json    # past_topics.json のテンプレート（Git 管理）
├── pyproject.toml              # pytest / ruff 設定（dev 専用）
└── com.example.daily-research.plist        # launchd plist テンプレート (5:00 research)
```

## Build / Test / Run

```bash
# 手動実行（Claude Code セッション内の Bash からも可 — lib/env.sh が CLAUDECODE を unset する。
# 呼1 は最長 25 分なので background + 長め timeout で）
./scripts/daily-research.sh

# テスト用 seam
DR_FORCE_TRACK=edge ./scripts/daily-research.sh   # 輪番外でも指定 1 line を今日の日付で実行
DR_ONLY_TRACK=akc ./scripts/daily-research.sh     # 当日担当 line のうち指定 line のみ
DR_DATE=2026-08-20 ./scripts/daily-research.sh    # 輪番とレポート名の日付を固定

# 認証確認
./scripts/check-auth.sh

# テスト
bats tests/                          # shell (orchestrator / lib / e2e mock)
.venv/bin/python -m pytest           # python (dr_pipeline モジュール、--cov 付き)
# .venv 初期化: uv venv && uv pip install pytest pytest-cov

# launchd 登録 (research 5:00)
cp com.example.daily-research.plist com.daily-research.plist          # → YOUR_USERNAME を編集
ln -sf "$(pwd)/com.daily-research.plist" ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.daily-research.plist

# ログ確認
tail -f logs/$(date +%Y-%m-%d).log
```

## Conventions

### 設計方針 (ADR-0008: per-repo in-context research → ADR-0010: rotation + 二層 eval)

- **rotation + daily line、line ごとに 2 呼び出し (ADR-0010 / ADR-0011)**: orchestrator が
  `dr_pipeline.py rotation-pick` (非 daily 行の epoch 日 % 行数、state レス・冪等、
  周期 = config 記述順。`daily = true` の line は輪番の外で毎日追加出力) で当日担当
  line 群を選び、line ごとに **呼1** = `claude -p` (model opus、25 分 timeout、
  transient 失敗は 1 回リトライ、401 は残 line 中断 — 完走済み line の集計は保持) を
  **cwd = target_repo** で実行。
  プロトコル正本は `prompts/repo-research-protocol.md` (`--append-system-prompt-file`)。
  per-line 注入 = `dr_pipeline.py line-brief` (focus / sources / context_files /
  self_signals) + past-themes (dedup) + テンプレート。**呼2** = fresh-context clarity
  改稿 (model sonnet、15 分、研究文脈なし、対象ノートのみ Edit 可、失敗は fail-open) —
  正本は `prompts/clarity-review-protocol.md`
- **目的関数 (ADR-0014、ADR-0009 を修正)**: 「repo に関係する外部の動向を 1 つ選び、
  何が起きたか・なぜ重要か・この repo にどう使えるかを、前提知識ゼロで読める解説レポートと
  して届ける」。主語は外部の出来事 — repo の立場への賛否・位置関係の議論を主題にしない。
  残す認識規律は「事実と解釈を分けて書く」だけ (裏付け禁止・反証義務・前提挑戦パスは
  2026-08-22 に撤去 — 反証過多で読めないレポートになった)。**発見ノルマなし**。
  承認要求・「すべき」・手順列挙は書かないが、使い道 (どの ADR / task / 問いにどう使えるか)
  は平文で書く — レポートは読み物であって作業指示ではない
- **run 構造**: 文脈読込 → diff パス (state/ の watched-sources を前回比差分だけ確認、
  re-survey 禁止。結果はテーマ候補の入力であり本文への網羅記述義務はない) → テーマ選択
  (候補 2〜3 → 3 問 Yes/No → 1 件。verdict 記録なし、ADR-0014) → リサーチ
  (citation ゲート = 全 URL を run 内 WebFetch 解決 + 自己汚染ガード) → vault へ note
  (推奨 4 節骨格: 結論 / 何が起きたか / 背景 / この repo への含意 + 固定 2 節、
  本文 3,000 字目安 — lint しない) → state 更新 (playbook は日付付き delta のみ) →
  呼2 clarity 改稿。スコアの保存・蓄積はしない (ADR-0006)
- **repo は read-only を三層で強制**: doctrine (プロトコル文言) + 書き込み先指定 +
  permission 層 (`--allowedTools` の Write/Edit を vault / state / past_topics の
  絶対パスに制限 + `--disallowedTools "Bash,Task,NotebookEdit"`)。**allow は加算リストで
  あって制限ではない** — `~/.claude/settings.json` の `defaultMode: "auto"` 下では
  列挙外の Bash が denial ゼロで通った (2026-08-22 PoC)。無人実行の境界は deny で書く
- **鮮度が一級制約**: LLM 界隈の知識は 1 週間スケールで陳腐化する。全 claim に
  as-of 日付、機会メモの全機会に失効日 (valid-until / 無効化イベント) を必須化
- **レポート存在ゲート (ctl-015)**: 各担当 line の成否は当日の
  `{date}_{track}_*.md` が vault に存在するかで決定論判定 (per line)。日次の
  final_class は全 line 成功 = OK / 一部失敗 = E_PARTIAL / 全滅 = E_NO_REPORT
  (ADR-0011 — E_NO_REPORT の「レポート 0 本」という意味を保つ)。失敗は line を
  明示して非ゼロ exit。呼2 clarity の失敗はゲートに影響しない (fail-open)
- **自己改善ループ (ADR-0006、preserve)**: 毎朝の run を `metrics.jsonl` (gitignore)
  に永続記録 (呼1 は pass2、呼2 は clarity_pass = ran/ok + 実測、pass1 は None、
  fallback_used はリトライ発生の意味、pass2 は全 attempt の合算、試験 seam の run は
  `source: "test"` で記録され expect-check / dr-review の集計から除外)。決定論レポート lint (ctl-016、hard fail のみ
  即日 notify) は固定 2 節 (機会メモ / ソース) を検査し `body_chars` を残す — 本文の
  記述規律の質は人間 consumer が判断。消費は対話 skill `/dr-review` (週 1 目安)。効果を意図した変更
  commit には `DR-Expect:` trailer。**事後採点の LLM judge は復活させない** —
  eval は run 内で verdict が消費される in-loop 型に限る (ADR-0010)
- **7:00 morning brief は廃止 (ADR-0009)**: 毎朝の Slack 承認リクエストが全ノートを
  「返答待ち todo」化していたため retire。期限付き機会はノート末尾の「機会メモ」を
  読むときに拾う (代替通知は意図的に作らない)
- **`--append-system-prompt-file`** を使用（`--system-prompt-file` ではない）。
  Claude Code のデフォルト能力を保持するため
- **`--allowedTools`** で最小権限: WebSearch, WebFetch, Read, Glob, Grep +
  path 制限付き Write/Edit、**`--disallowedTools`** で Bash 等を deny (呼1 / 呼2 共通)。
  `--dangerously-skip-permissions` は使わない。呼2 の allowedTools に埋めるノート名は
  basename 検証済みのものだけ (カンマ入り slug でルール注入できるため)
- **`< /dev/null`**: 全 `claude -p` 呼び出しで stdin をリダイレクト
- **オーケストレーションは shell**、JSON/TOML 解析は stdlib python3
  (`scripts/lib/dr_pipeline.py`)。pip 依存はランタイムに導入しない

### 設定ファイル

- `config.toml` と `past_topics.json` は個人データのため `.gitignore` に含まれる
- Git に含まれるのは `config.example.toml` と `past_topics.example.json`
- 設定を変更する場合は `config.toml` を直接編集する（example は公開テンプレート）
- `state/` (watched-sources / playbook) も運用 private で gitignore

### レポート出力

- 出力先: `{vault_path}/{output_dir}/{date}_{track}_{slug}.md`（flat dir — ctl-015 /
  ctl-016 / wiki ingest が前提にする）
- **本文は自由形式** (ADR-0009)。ただし記述規律 3 点 (冒頭に結論 / 初見の読者向けの
  背景 / 全 claim に as-of 日付と事実・解釈の分離) を課す (ADR-0014 で 5 点から縮約) —
  正本は `templates/report-template.md`
- 固定節は末尾 2 つのみ (ctl-016 の機械検査対象): **機会メモ**（日付付き締切を持つ
  機会だけを 何を / どこで / 失効日 の 3 行定型で。無い日は「なし」）と
  **ソース**（最低 5 件、全 URL run 内解決済み）。ctl-016 の検査は非対称: `## ソース`
  不在と出典 URL 0 件は hard fail、`## 機会メモ` 欠落 (`ARTICLE_SECTIONS` はこれ 1 つ) と
  出典 < min_sources・本文 < 1,500 字は soft
- **repo は read-only 参照のみ**。deploy・台帳更新はしない — note は読み物であって
  deploy ではない。取り込みは運用者が repo セッションで gate を通して行う

### プロンプト編集時の注意

- `prompts/repo-research-protocol.md` がリサーチの質を決める中核ファイル
  (目的関数・7 step・テーマ選別チェックリスト・失効規律の正本)
- `prompts/clarity-review-protocol.md` は呼2 の正本 — 欠陥検出限定 (新事実の追加・
  ソース節/機会メモ/frontmatter の変更は禁止)。品質バーを広げる改稿は入れない
- `templates/report-template.md` は記述規律と固定 2 節の定義。**固定節の見出しを
  変えるときは ctl-016 の検査 (`dr_pipeline.py` の `ARTICLE_SECTIONS` = 機会メモ、および
  `## ソース` の別建て hard check) を必ず同期する**
- プロンプトファイルは全て日本語

### 過去に試行・棄却した機能

- **concept-graph 駆動のテーマ選定 (2 パス構成)**: Pass 1 (Opus) が `.repo-graphs/`
  同期コピー + coverage-report / cluster-report からテーマ JSON を選定し Pass 2
  (Sonnet) が執筆する構成。repo を概念体系フィルター越しにしか見ないため出力が
  「framework の裏付け」に収束 (corroboration failure mode は PseudoBench
  arXiv:2606.18060 でベンチマーク実証済み) → 2026-08-04 に per-repo in-context
  research へ全面移行 (ADR-0008)。coverage/cluster/validate-theme/bootstrap-graph/
  lib/graph.sh は削除 (git history で復元可能)、`graph.jsonld` は凍結アーカイブ
- **評価フレームワーク (LLM-as-Judge)**: コスト対効果が低く 2026-02 運用停止 →
  2026-06-29 完全削除。後継は決定論収集 + 人間 consumer の自己改善ループ (ADR-0006)
- **エージェントチーム版**: コスト・時間対効果が低く棄却。コードは git history (`a79074e`)
- **Mem0 Cloud MCP 統合**: 32 日間ゼロ稼働で 2026-05-23 撤去
- **汎用トレンドリサーチ / 自由探索 line**: 固定 domains の構造的飽和 (2026-05-27 廃止)
  → cluster 反発付きで一時復活 (ADR-0004) → 関心乖離で全廃 (ADR-0007) → 担い手の
  Pass 1 ごと削除 (ADR-0008)。復活には別の実行形の設計が必要

## Status

- 本番稼働中。毎朝 AM 5:00 に launchd で自動実行 (7:00 Slack ブリーフは ADR-0009 で廃止)
- **rotation + 二層 eval (2026-08-13 再設計 = ADR-0010) + daily line (2026-08-14)**:
  毎朝、`akc` / `contemplative` / `aap` / `authorship` / `ans` / `desire` の 6 line の
  輪番 1 line (6 日周期) + daily line `edge` の計 2 line を実行。`desire` は 2026-08-14〜18
  のみ `daily = true` で毎日実行 (ADR-0011)、2026-08-18 に輪番へ戻した (ADR-0012)。
  2026-08-20 に `edge` (AI 活用の限界突破事例、接地 repo = edge-frontier) を daily で
  新設 (ADR-0013)。
  呼1 = Opus 研究 (テーマ選択込み)、呼2 = Sonnet clarity 改稿。ライン数・repo
  マッピング・輪番順は config.toml から動的取得。
  **2026-08-22 にレポートを「動向解説 + repo への含意」へ単純化 (ADR-0014)**: 対立的
  フレーミング (裏付け禁止 / 反証義務 / 前提挑戦パス / theme_rank / scoring_criteria) を
  プロトコル・テンプレート・config の 3 層から撤去。可読性の主観判定は 2026-08-30
- 蓄積層: Obsidian vault の LLM-wiki (ingest は Pass 3 で継続) + line 別 state
  (watched-sources / playbook)。中央 graph.jsonld は凍結アーカイブ
