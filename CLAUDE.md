# daily-research

Claude Code 非対話モード (`claude -p`) + macOS launchd で毎朝 AM 5:00 に自律リサーチを実行するシステム。4 つの研究ライン (line) が 4 つの DOI 登録済み研究 repo に 1:1 でマッピングされる (`akc` = agent-knowledge-cycle / `contemplative` = contemplative-agent / `aap` = agent-attribution-practice / `authorship` = authorship-strategy)。**per-repo in-context research (ADR-0008)**: 各 line は `claude -p` を **cwd = 対象 repo** で 1 回ずつ実行し、repo 自身の運用文脈 (CLAUDE.md / タスク台帳 / open questions / 実施履歴) から「この line を今すぐ前に進める実行可能な手」をリサーチして actionable-tactics note を Obsidian vault に出力する。毎朝 AM 7:00 に `morning-brief.sh` が当日ノートの手を決定論抽出し Slack へ承認リクエストを送る。

## Tech Stack

- Shell script (Bash) — オーケストレーション層
- **Sanctioned runtime ルール**: pip 依存なし。ランタイムは bash + stdlib python3 (>=3.11,
  tomllib 必須) + coreutils `timeout`。JSON/TOML 解析は `scripts/lib/dr_pipeline.py`
  (stdlib のみ: json/tomllib/re) に集約。homebrew `/opt/homebrew/bin/python3` を使う
  (system 3.9.6 は tomllib 不足で不可)
- Claude Code CLI (`claude -p`) — 非対話モード
- TOML — 設定ファイル (`config.toml`)
- launchd — macOS スケジューラ (5:00 research / 7:00 morning brief)
- bats (shell) + pytest (python) — テスト。pytest は dev/test 専用 (`.venv`)、
  ランタイムには載らない

## Directory Structure

```
daily-research/
├── scripts/
│   ├── daily-research.sh       # オーケストレータ（per-line ループ: cwd=repo で claude -p）
│   ├── morning-brief.sh        # 7:00 Slack 承認ブリーフ（決定論抽出 + wiki_notify 再利用）
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
│   └── report-template.md      # actionable-tactics note テンプレート（YAML frontmatter 付き）
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
│   └── adr/                         # アーキテクチャ決定記録（0001-0008 + README）
├── com.example.daily-research.plist        # launchd plist テンプレート (5:00 research)
└── com.example.daily-research-brief.plist  # launchd plist テンプレート (7:00 brief)
```

## Build / Test / Run

```bash
# 手動実行（別ターミナルで。Claude Code セッションと同じターミナルでは不可）
./scripts/daily-research.sh

# 朝ブリーフの手動実行 (当日ノートから抽出して Slack 送信)
./scripts/morning-brief.sh

# 認証確認
./scripts/check-auth.sh

# テスト
bats tests/                          # shell (orchestrator / lib / e2e mock)
.venv/bin/python -m pytest           # python (dr_pipeline モジュール、--cov 付き)
# .venv 初期化: uv venv && uv pip install pytest pytest-cov

# launchd 登録 (research 5:00 / brief 7:00)
cp com.example.daily-research.plist com.daily-research.plist          # → YOUR_USERNAME を編集
cp com.example.daily-research-brief.plist com.daily-research-brief.plist
ln -sf "$(pwd)/com.daily-research.plist" ~/Library/LaunchAgents/
ln -sf "$(pwd)/com.daily-research-brief.plist" ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.daily-research.plist
launchctl load ~/Library/LaunchAgents/com.daily-research-brief.plist

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
- **目的関数**: 「この line を今すぐ前に進める、実行可能な手を見つける」。
  裏付け (corroboration) を主旨とするノートは禁止。**手数ノルマなし** —
  「本日 actionable なし」は証拠付きの正の出力 (Goodhart 回避)
- **run 構造**: 文脈読込 → diff パス (state/ の watched-sources を前回比差分だけ確認、
  re-survey 禁止、失効項目の再検証) → 価値選定 → リサーチ (citation ゲート =
  全 URL を run 内 WebFetch 解決) → 前提挑戦パス (「矛盾・複雑化する知見」必須節 +
  自己汚染ガード) → vault へ note → state 更新 (playbook は日付付き delta のみ)
- **repo は read-only を三層で強制**: doctrine (プロトコル文言) + 書き込み先指定 +
  permission 層 (`--allowedTools` の Write/Edit を vault / state / past_topics の
  絶対パスに制限)
- **鮮度が一級制約**: LLM 界隈の知識は 1 週間スケールで陳腐化する。全 claim に
  as-of 日付、全「手」に失効条件 (valid-until / 無効化イベント) を必須化
- **レポート存在ゲート (ctl-015、line 単位)**: 各 line の成否は当日の
  `{date}_{track}_*.md` が vault に存在するかで決定論判定。全 line 通過で成功、
  部分失敗は失敗 line を明示して非ゼロ exit
- **自己改善ループ (ADR-0006、preserve)**: 毎朝の run を `metrics.jsonl` (gitignore)
  に永続記録 (per-line run 群は pass2 に合算、pass1 は None、fallback_used は
  リトライ発生の意味)。決定論レポート lint (ctl-016、hard fail のみ即日 notify) は
  新テンプレートの必須節を検査。消費は対話 skill `/dr-review` (週 1 目安)。
  効果を意図した変更 commit には `DR-Expect:` trailer。LLM judge は復活させない
- **7:00 morning brief**: `morning-brief.sh` が当日ノートの「今すぐ実行可能な手」節を
  **awk で決定論抽出** (LLM を挟まない — vault notify.sh の injection-guard 設計に従い
  送信は呼び出し元シェル) し、vault の `wiki_notify` (Slack webhook + macOS fallback) で
  承認リクエスト送信。承認・deploy 前 gate は運用者の次セッションの行為
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
- **リード節 = 「今すぐ実行可能な手」**（1〜3 件、各: 何を / どこで / 手順 / 所要 /
  失効条件 / gate 留意。0 件の日は証拠付き「本日 actionable なし」）
- 必須節: 差分と失効チェック / 根拠と新規シグナル / 我々の立場と矛盾・複雑化する知見 /
  開いた問い / ソース（最低 5 件、全 URL run 内解決済み）
- **repo は read-only 参照のみ**。deploy・台帳更新はしない — note は提案であって
  deploy ではない。取り込みは運用者が朝ブリーフ承認 → repo セッションで gate を通して行う

### プロンプト編集時の注意

- `prompts/repo-research-protocol.md` がリサーチの質を決める中核ファイル
  (目的関数・7 step・失効規律の正本)
- `templates/report-template.md` は出力フォーマットの定義。**見出しを変えるときは
  ctl-016 の必須節リスト (`dr_pipeline.py` ARTICLE_SECTIONS) と `morning-brief.sh` の
  抽出見出しを必ず同期する**
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

- 本番稼働中。毎朝 AM 5:00 に launchd で自動実行、AM 7:00 に Slack 承認ブリーフ
- **per-repo in-context research (2026-08-04 再設計 = ADR-0008)**: `akc` /
  `contemplative` / `aap` / `authorship` の 4 line が各 repo を cwd に単一パス実行。
  ライン数・repo マッピングは config.toml から動的取得
- 蓄積層: Obsidian vault の LLM-wiki (ingest は Pass 3 で継続) + line 別 state
  (watched-sources / playbook)。中央 graph.jsonld は凍結アーカイブ
