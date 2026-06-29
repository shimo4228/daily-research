# daily-research

Claude Code 非対話モード (`claude -p`) + macOS launchd で毎朝 AM 5:00 に自律リサーチを実行するシステム。各 track を 1 つの DOI 登録済み研究 repo にマッピングし、repo の概念体系 (graph.jsonld) の「未補強 concept」を補強する最新外部研究をリサーチして Obsidian vault に出力する。

## Tech Stack

- Shell script (Bash) — オーケストレーション層
- **Sanctioned runtime ルール**: pip 依存なし。ランタイムは bash + stdlib python3 (>=3.11,
  tomllib 必須) + coreutils `timeout`。JSON/TOML 解析は `scripts/lib/dr_pipeline.py`
  (stdlib のみ: json/tomllib/re) に集約。homebrew `/opt/homebrew/bin/python3` を使う
  (system 3.9.6 は tomllib 不足で不可)。「Python ゼロ」は実態と矛盾していたため廃止
- Claude Code CLI (`claude -p`) — 非対話モード
- TOML — 設定ファイル (`config.toml`)
- launchd — macOS スケジューラ
- bats (shell) + pytest (python) — テスト。pytest は dev/test 専用 (`.venv`)、
  ランタイムには載らない

## Directory Structure

```
daily-research/
├── scripts/
│   ├── daily-research.sh       # オーケストレータ（lib を source、preflight → Pass 1/2/3）
│   ├── lib/                    # sourced ライブラリ + python 解析モジュール
│   │   ├── env.sh              # 環境サニタイズ + PATH
│   │   ├── log.sh              # log() / log_init()（作成時 chmod、30日ローテーション）
│   │   ├── notify.sh           # notify()（osascript ガード）
│   │   ├── lock.sh             # acquire_lock()/release_lock()（mkdir アトミック）
│   │   ├── graph.sh            # check_graph_health()/sync_repo_graphs()
│   │   ├── auth.sh             # real_auth_probe()（実 OAuth probe、3 entrypoint 共有）
│   │   ├── claude.sh           # run_claude()/classify_exit()（E_AUTH/E_TRANSIENT/E_FATAL）
│   │   └── dr_pipeline.py      # JSON/TOML 解析の単一モジュール（旧 inline python を集約）
│   ├── bootstrap-graph.sh      # graph.jsonld 初回 bootstrap（ワンショット、Opus clustering）
│   ├── coverage-report.sh      # 未補強 concept レポート生成（Pass 1 へ注入）
│   └── check-auth.sh           # OAuth トークンの実 probe ヘルスチェック（lib/auth.sh を共有）
├── prompts/
│   ├── theme-selection-prompt.md # Pass 1: repo graph 駆動のテーマ選定プロンプト
│   ├── task-prompt.md            # Pass 2: Sonnet リサーチ・執筆タスク指示
│   └── research-protocol.md     # Pass 2: リサーチプロトコル（品質の中核）
├── templates/
│   └── report-template.md      # レポートの Markdown テンプレート（YAML frontmatter 付き）
├── graph.jsonld                # 永続メモリ層: concept cluster graph + repo 補強履歴（Git 管理）
├── .repo-graphs/               # 各 track の repo graph 同期コピー（起動時生成、.gitignore）
├── config.toml                 # トラック=repo マッピング・スコアリング基準・出力設定（.gitignore）
├── config.example.toml         # config.toml のテンプレート（Git 管理）
├── past_topics.json            # 過去テーマ履歴（.gitignore）
├── logs/                       # 実行ログ（30日でローテーション、.gitignore）
├── tests/                      # bats（daily-research / e2e-mock / lib）+ pytest（dr_pipeline_test.py）+ fixtures/
├── docs/
│   ├── RUNBOOK.md / RUNBOOK.ja.md   # 運用ガイド
│   ├── CONTRIB.md / CONTRIB.ja.md   # 開発ガイド
│   ├── graph-schema.md              # graph.jsonld スキーマ仕様（concept cluster + reinforces）
│   └── progress/                    # ポストモーテム・評価レポート
└── com.example.daily-research.plist  # launchd plist テンプレート
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

# launchd 登録
cp com.example.daily-research.plist com.daily-research.plist
# → YOUR_USERNAME を編集
ln -sf "$(pwd)/com.daily-research.plist" ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.daily-research.plist

# ログ確認
tail -f logs/$(date +%Y-%m-%d).log
```

## Conventions

### 設計方針

- **2パス方式**: Pass 1 (Opus: repo graph + coverage-report を読んで未補強 concept を補強するテーマ選定) → Pass 2 (Sonnet: リサーチ・執筆 + graph.jsonld 増分更新)
- **各 track = 1 研究 repo (concept coverage gap 駆動)**: 起動時に各 track の repo graph を `.repo-graphs/` へ sync、`coverage-report.sh` が「repo の全 concept − graph.jsonld の reinforces 済み concept」= 未補強 concept を算出し Pass 1 に注入。Pass 1 は未補強 concept を補強する外部研究を選定し、Pass 2 が `reinforces` を graph に記録する
- Pass 1 失敗時は Sonnet が一括フォールバック（テーマ選定も担当）
- **`--append-system-prompt-file`** を使用（`--system-prompt-file` ではない）。Claude Code のデフォルト能力を保持するため
- **`--allowedTools`** で最小権限。`--dangerously-skip-permissions` は使わない
  - Pass 1 (Opus): WebSearch, WebFetch, Read, Glob, Grep
  - Pass 2 (Sonnet): WebSearch, WebFetch, Read, Write, Edit, Glob, Grep
- **`< /dev/null`**: 全 `claude -p` 呼び出しで stdin をリダイレクト。他 MCP の stdio 通信とのコンフリクトを防止
- **オーケストレーションは shell**、JSON/TOML 解析は stdlib python3 (`scripts/lib/dr_pipeline.py`)。
  pip 依存はランタイムに導入しない (test の pytest を除く)。新規 framework も入れない

### 設定ファイル

- `config.toml` と `past_topics.json` は個人データのため `.gitignore` に含まれる
- Git に含まれるのは `config.example.toml` と `past_topics.example.json`
- 設定を変更する場合は `config.toml` を直接編集する（example は公開テンプレート）

### レポート出力

- 出力先: `{vault_path}/{output_dir}/{date}_{track}_{slug}.md`
- vault_path は `config.toml` の `[general].vault_path` で指定
- レポートは散文主体。箇条書きは比較表や4項目以上の並列列挙のみ
- 出典は最低5件、URL 必須
- 「未解決の問い」「反証・緊張関係」節で外部研究側の gap と repo concept への挑戦を記録（開発アイデア節は 2026-06-06 廃止 — repo 内部状態を知らないため的外れになりやすく、寄与節と重複していた）
- 各レポート末尾に「この repo への寄与」節（補強 concept / 拡張・挑戦 / 取り込み提案の 3 点構造）
- **repo は read-only 参照のみ**。寄与は vault レポート経由で人間が手で取り込む（daily-research は repo を直接編集しない）

### プロンプト編集時の注意

- `prompts/theme-selection-prompt.md` がテーマ選定の指示（Pass 1）
- `prompts/research-protocol.md` がリサーチの質を決める中核ファイル（Pass 2）
- `templates/report-template.md` は出力フォーマットの定義
- プロンプトファイルは全て日本語。出力言語の変更は protocol.md を修正

### 過去に試行・棄却した機能

- **評価フレームワーク (LLM-as-Judge)**: 6次元ルーブリック（Factual Grounding / Depth / Coherence / Specificity / Novelty / Actionability、各1-5点）を Pass 2 成功後に Opus judge で採点していた。コスト対効果が低く 2026-02 以降運用停止 → 2026-06-29 に完全削除（`evals/` / `scripts/eval-run.sh` / `tests/test-eval.bats`）。コードは git history で復元可能
- **エージェントチーム版**: コスト・時間対効果が低く棄却。詳細は `docs/progress/` のポストモーテム参照。コードは git history (`a79074e`) で復元可能
- **Mem0 Cloud MCP 統合**: 2026-02-26 に main へマージしたが `.mcp.json` 不在 + ヘルスチェック形骸化により 32 日間ゼロ稼働。2026-05-23 撤去。後継はローカル JSON-LD concept cluster graph (`graph.jsonld`)
- **汎用トレンドリサーチ (tech/personal/ai_dev)**: 固定 domains が構造的飽和を招いた（contemplative 系 37%）ため 2026-05-27 に廃止。各 track を研究 repo にマッピングする方式へ転換

## Status

- 本番稼働中。毎朝 AM 5:00 に launchd で自動実行
- Opus テーマ選定 + Sonnet リサーチ・執筆の2パス方式（E2E 検証済み、2026-02-20）
- **4トラック構成 (各 track = 1 DOI 登録済み研究 repo)**: `authorship` (authorship-strategy) / `contemplative` (contemplative-agent) / `aap` (agent-attribution-practice) / `akc` (agent-knowledge-cycle)。トラック数・マッピングは config.toml から動的取得
- 永続メモリ層: JSON-LD concept cluster graph (`graph.jsonld`) 稼働中。Pass 2 が日次増分更新、起動時 health check
- repo graph の未補強 concept を補強する R&D フィードバックエンジンとして稼働（2026-05-27 転換、Pass 1/2 の E2E は翌朝 launchd で検証予定）
- Pass 1 失敗時は Sonnet 一括フォールバックで継続稼働
