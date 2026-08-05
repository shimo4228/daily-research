# daily-research

Claude Code 非対話モード (`claude -p`) + macOS launchd で毎朝 AM 5:00 に自律リサーチを実行するシステム。5 つの研究ライン (line) が 5 つの DOI 登録済み研究 repo に 1:1 でマッピングされる (`akc` = agent-knowledge-cycle / `contemplative` = contemplative-agent / `aap` = agent-attribution-practice / `authorship` = authorship-strategy / `ans` = attention-not-self)。**per-repo in-context research (ADR-0008)**: 各 line は `claude -p` を **cwd = 対象 repo** で 1 回ずつ実行し、repo 自身の運用文脈 (CLAUDE.md / タスク台帳 / open questions / 実施履歴) から「repo の前提・問い・立場を動かす外部の動き」をリサーチする。出力は**前提知識ゼロで読める自由形式の解説レポート** (ADR-0009) を Obsidian vault へ — 提案・承認要求は書かず、日付付き締切を持つ機会だけを末尾「機会メモ」に記録する。7:00 の Slack 承認ブリーフは廃止済み (ADR-0009)。

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
│   ├── daily-research.sh       # オーケストレータ（per-line ループ: cwd=repo で claude -p）
│   ├── lib/                    # sourced ライブラリ + python 解析モジュール
│   │   ├── env.sh              # 環境サニタイズ + PATH
│   │   ├── log.sh              # log() / log_init()（作成時 chmod、30日ローテーション）
│   │   ├── notify.sh           # notify()（osascript ガード）
│   │   ├── lock.sh             # acquire_lock()/release_lock()（mkdir アトミック）
│   │   ├── auth.sh             # real_auth_probe()（実 OAuth probe）
│   │   ├── claude.sh           # run_claude()/classify_exit()（E_AUTH/E_TRANSIENT/E_FATAL）
│   │   └── dr_pipeline.py      # JSON/TOML 解析の単一モジュール（line-brief / past-themes /
│   │                           #   report-lint / metrics-* / expect-check 等）
│   ├── check-auth.sh           # OAuth トークンの実 probe ヘルスチェック
│   └── pre-commit.sh           # secret / 構文ガード（git pre-commit hook）
├── prompts/
│   └── repo-research-protocol.md # per-repo リサーチ・プロトコル（品質の中核、ADR-0008）
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
│   └── adr/                         # アーキテクチャ決定記録（0001-0009 + README）
└── com.example.daily-research.plist        # launchd plist テンプレート (5:00 research)
```

## Build / Test / Run

```bash
# 手動実行（別ターミナルで。Claude Code セッションと同じターミナルでは不可）
./scripts/daily-research.sh

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

### 設計方針 (ADR-0008: per-repo in-context research)

- **per-repo 単一パス**: orchestrator が config.toml の line ごとに `claude -p`
  (model sonnet、25 分 timeout、transient 失敗は 1 回リトライ、401 は全 line 中断) を
  **cwd = target_repo** で実行。プロトコル正本は `prompts/repo-research-protocol.md`
  (`--append-system-prompt-file`)。per-line 注入 = `dr_pipeline.py line-brief`
  (focus / 判断基準 / context_files / self_signals) + past-themes (dedup) + テンプレート
- **目的関数 (ADR-0009)**: 「repo の前提・問い・立場を動かす外部の動きを見つけ、
  前提知識ゼロで読める解説レポートとして届ける」。裏付け (corroboration) を主旨とする
  ノートは禁止。**発見ノルマなし** — 「変化なし」は根拠付きの正の出力 (Goodhart 回避)。
  提案・承認要求・作業手順は書かない — レポートは読み物であって作業指示ではない
- **run 構造**: 文脈読込 → diff パス (state/ の watched-sources を前回比差分だけ確認、
  re-survey 禁止、失効項目の再検証) → 価値選定 → リサーチ (citation ゲート =
  全 URL を run 内 WebFetch 解決) → 前提挑戦パス (反対材料の記述義務 +
  自己汚染ガード) → vault へ note → state 更新 (playbook は日付付き delta のみ)
- **repo は read-only を三層で強制**: doctrine (プロトコル文言) + 書き込み先指定 +
  permission 層 (`--allowedTools` の Write/Edit を vault / state / past_topics の
  絶対パスに制限)
- **鮮度が一級制約**: LLM 界隈の知識は 1 週間スケールで陳腐化する。全 claim に
  as-of 日付、機会メモの全機会に失効日 (valid-until / 無効化イベント) を必須化
- **レポート存在ゲート (ctl-015、line 単位)**: 各 line の成否は当日の
  `{date}_{track}_*.md` が vault に存在するかで決定論判定。全 line 通過で成功、
  部分失敗は失敗 line を明示して非ゼロ exit
- **自己改善ループ (ADR-0006、preserve)**: 毎朝の run を `metrics.jsonl` (gitignore)
  に永続記録 (per-line run 群は pass2 に合算、pass1 は None、fallback_used は
  リトライ発生の意味)。決定論レポート lint (ctl-016、hard fail のみ即日 notify) は
  固定 2 節 (機会メモ / ソース) を検査 — 本文の記述規律の質は人間 consumer が判断。
  消費は対話 skill `/dr-review` (週 1 目安)。効果を意図した変更 commit には
  `DR-Expect:` trailer。LLM judge は復活させない
- **7:00 morning brief は廃止 (ADR-0009)**: 毎朝の Slack 承認リクエストが全ノートを
  「返答待ち todo」化していたため retire。期限付き機会はノート末尾の「機会メモ」を
  読むときに拾う (代替通知は意図的に作らない)
- **`--append-system-prompt-file`** を使用（`--system-prompt-file` ではない）。
  Claude Code のデフォルト能力を保持するため
- **`--allowedTools`** で最小権限: WebSearch, WebFetch, Read, Glob, Grep +
  path 制限付き Write/Edit。`--dangerously-skip-permissions` は使わない
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
- **本文は自由形式** (ADR-0009)。ただし記述規律 5 点 (冒頭に結論 / 前提知識ゼロ向けの
  背景解説 / 反対材料を最低 1 件 / 定点観測結果 / 全 claim に as-of 日付) を課す —
  正本は `templates/report-template.md`
- 固定節は末尾 2 つのみ (ctl-016 の機械検査対象): **機会メモ**（日付付き締切を持つ
  機会だけを 何を / どこで / 失効日 の 3 行定型で。無い日は「なし」）と
  **ソース**（最低 5 件、全 URL run 内解決済み）
- **repo は read-only 参照のみ**。deploy・台帳更新はしない — note は読み物であって
  deploy ではない。取り込みは運用者が repo セッションで gate を通して行う

### プロンプト編集時の注意

- `prompts/repo-research-protocol.md` がリサーチの質を決める中核ファイル
  (目的関数・7 step・失効規律の正本)
- `templates/report-template.md` は記述規律と固定 2 節の定義。**固定節の見出しを
  変えるときは ctl-016 の必須節リスト (`dr_pipeline.py` ARTICLE_SECTIONS) を必ず同期する**
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
- **per-repo in-context research (2026-08-04 再設計 = ADR-0008)**: `akc` /
  `contemplative` / `aap` / `authorship` / `ans` の 5 line が各 repo を cwd に単一パス実行。
  ライン数・repo マッピングは config.toml から動的取得
- 蓄積層: Obsidian vault の LLM-wiki (ingest は Pass 3 で継続) + line 別 state
  (watched-sources / playbook)。中央 graph.jsonld は凍結アーカイブ
