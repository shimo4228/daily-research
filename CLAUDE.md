# daily-research

Claude Code 非対話モード (`claude -p`) + macOS launchd で毎朝 AM 5:00 に自律リサーチを実行するシステム。7 つの研究ライン (line) が 7 つの研究 repo に 1:1 でマッピングされる (`akc` = agent-knowledge-cycle / `contemplative` = contemplative-agent / `aap` = agent-attribution-practice / `authorship` = authorship-strategy / `ans` = attention-not-self / `desire` = desire-frontier / `edge` = edge-frontier。desire / edge 以外は DOI 登録済み)。これに加えて、接地 repo を持たない ecosystem line `jev` (Jev エコシステムの毎日観測、`mode = "ecosystem"` + `daily = true`、ADR-0018) が輪番の外で毎朝 1 本走る。**輪番 window + 二層 eval (ADR-0010 / ADR-0017)**: 毎朝、`[general] lines_per_day = 3` に従って 7 line から連続 3 本を輪番 window で選び、各 line が `claude -p` を **cwd = 対象 repo** で実行し (per-repo in-context research, ADR-0008)、repo 自身の運用文脈 (CLAUDE.md / タスク台帳 / open questions / 実施履歴) から「repo に関係する外部の動向」を 1 つ**問いの形で**選んで解説し、repo への含意を添える (ADR-0014)。run は短い line brief から始めて問いの候補を並べ、**通常記事 / 短報 / 更新なし / 保留**の 4 状態のどれかで正直に終える (run receipt に記録)。執筆後に fresh-context の呼2 が clarity を直し、根拠ファイルの主張を原典で再取得して照合する。出力は**前提知識ゼロで読める自由形式の解説レポート** (ADR-0009) を Obsidian vault へ — 提案・承認要求は書かず、日付付き締切を持つ機会だけを末尾「機会メモ」に記録する。7:00 の Slack 承認ブリーフは廃止済み (ADR-0009)。

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
│   ├── daily-research.sh       # オーケストレータ（輪番 window で 3 line、各 line 呼1 研究 + 呼2 検証 + clarity）
│   ├── lib/                    # sourced ライブラリ + python 解析モジュール
│   │   ├── env.sh              # 環境サニタイズ + PATH
│   │   ├── log.sh              # log() / log_init()（作成時 chmod、30日ローテーション）
│   │   ├── notify.sh           # notify()（osascript ガード）
│   │   ├── lock.sh             # acquire_lock()/release_lock()（mkdir アトミック）
│   │   ├── auth.sh             # real_auth_probe()（実 OAuth probe）
│   │   ├── claude.sh           # run_claude()/classify_exit()（E_AUTH/E_TRANSIENT/E_FATAL）
│   │   └── dr_pipeline.py      # JSON/TOML 解析の単一モジュール（rotation-pick / line-brief /
│   │                           #   past-themes / receipt-read / verify-read / report-lint /
│   │                           #   metrics-* / expect-check / config-get 等）
│   ├── check-auth.sh           # OAuth トークンの実 probe ヘルスチェック
│   └── pre-commit.sh           # secret / 構文ガード（git pre-commit hook）
├── prompts/
│   ├── repo-research-protocol.md # per-repo リサーチ・プロトコル（品質の中核、ADR-0008。
│   │                             #   Step 3 問いの選定と 4 内容状態 = ADR-0017）
│   ├── ecosystem-research-protocol.md # ecosystem line の呼1（接地 repo なし。watchlist 差分 + 未知探索の
│   │                             #   二経路、変化単位の dedup。共有契約は repo 版と同じ、ADR-0018）
│   └── verification-protocol.md  # 呼2 fresh-context の clarity + 原典照合プロトコル（ADR-0017）
├── templates/
│   ├── report-template.md      # 解説レポートの記述規律 + 固定 2 節（YAML frontmatter 付き）
│   ├── report-template-edge.md # edge line 専用の節構成（手筋収穫型、ADR-0015）
│   └── report-template-ecosystem.md # ecosystem line 用（repo 前提の文言なし、固定 2 節は共通、ADR-0018）
├── state/                      # line 別の状態（brief.md / pending.md / watched-sources.md /
│                               #   playbook.md / runs/{date}.md 根拠ファイル / runs/{date}.json receipt /
│                               #   runs/{date}.verify.json、.gitignore）
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
│   └── adr/                         # アーキテクチャ決定記録（0001-0018 + README）
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
DR_FORCE_TRACK=edge ./scripts/daily-research.sh   # 当日の輪番 window 外でも指定 1 line を今日の日付で実行
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

- **輪番 window、line ごとに 2 呼び出し (ADR-0010 / ADR-0017)**: orchestrator が
  `dr_pipeline.py rotation-pick` (`K = [general] lines_per_day`、`N` = 輪番 line 数、
  開始位置 = 序数 × K mod N、そこから連続 K 本。state レス・冪等、周期 = config 記述順。
  K=1 は旧来の 1 line 選択と同じ位相。`daily = true` の line は輪番の外で毎日追加出力され、
  機構は schema に残る) で当日担当 line 群を選び、line ごとに **呼1** = `claude -p`
  (model opus、25 分 timeout、transient 失敗は 1 回リトライ、401 は残 line 中断 —
  完走済み line の集計は保持) を **cwd = target_repo** で実行。
  プロトコル正本は `prompts/repo-research-protocol.md` (`--append-system-prompt-file`)。
  per-line 注入 = `dr_pipeline.py line-brief` (focus / sources / self_signals。
  `context_files` は「選定後に読む候補」として別節) + past-themes (問い単位の dedup) +
  テンプレート。**呼2** = fresh-context の検証 + clarity (model は `[verification] model`、
  既定 sonnet。20 分、max-turns 30、研究文脈なし、Read + WebFetch + 対象ノートと
  verify.json のみ Edit 可、WebSearch は disallow、失敗は fail-open) — 正本は
  `prompts/verification-protocol.md`
- **4 つの内容状態 (ADR-0017)**: 1 line の run は `article` (通常記事) / `brief`
  (300〜600 字の短報) / `quiet` (更新なし) / `hold` (保留) のいずれかで終える。状態は
  呼1 が記事の直後に書く run receipt `state/<line>/runs/{date}.json`
  (`{date, line, status, report, question, reason, reason_code}`) が正本。
  「毎回新テーマを十分な長さで完結」は目的関数ではない — 材料が薄い日に quiet / hold を
  選ぶのは正常な結果で、全 line quiet の日も成功 (exit 0)
- **目的関数 (ADR-0014、ADR-0009 を修正)**: 「repo に関係する外部の動向を 1 つ選び、
  何が起きたか・なぜ重要か・この repo にどう使えるかを、前提知識ゼロで読める解説レポートと
  して届ける」。主語は外部の出来事 — repo の立場への賛否・位置関係の議論を主題にしない。
  残す認識規律は「事実と解釈を分けて書く」だけ (裏付け禁止・反証義務・前提挑戦パスは
  2026-08-22 に撤去 — 反証過多で読めないレポートになった)。**発見ノルマなし**。
  承認要求・「すべき」・手順列挙は書かないが、使い道 (どの ADR / task / 問いにどう使えるか)
  は平文で書く — レポートは読み物であって作業指示ではない
- **run 構造**: 短い文脈読込 (line brief + `state/<line>/brief.md` + 問いの履歴 +
  `pending.md` + self_signals。repo の詳細は読まない) → diff パス (watched-sources を
  前回比差分だけ確認、re-survey 禁止。結果は問いの候補の入力であり本文への網羅記述義務は
  ない) + 広い探索 → 問いの候補 3〜6 件を定型なしで列挙し 1 つ選ぶ (または quiet / hold
  を選ぶ) → 選定後に関係する ADR / 台帳 / `context_files` だけ Read → リサーチ
  (citation ゲート = 全 URL を run 内 WebFetch 解決 + 自己汚染ガード。原典が問いの前提を
  崩したら問いを 1 回まで改訂してよい) → 根拠ファイル `runs/{date}.md` (claim 3〜6 件を
  source / locator / provenance / fetch_status 付きの表で) → vault へ note (固定見出しなし +
  末尾固定 2 節) → receipt `runs/{date}.json` → state 更新 (playbook は日付付き delta
  のみ) → 呼2 検証 + clarity。スコアの保存・蓄積はしない (ADR-0006)
- **ecosystem mode (ADR-0018)**: `[tracks.<x>].mode = "ecosystem"` の line は接地 repo を持たず、
  **外部エコシステムの変化そのもの**を観測する (「repo に関係する外部の動向」という目的関数を課さない。
  運用者の harness・研究 repo への適用可能性は選定条件にしない)。実行形は mode から決まり、line 名では
  分岐しない: 呼1 の cwd = `state/<line>/` (手元の文脈は line-local state だけ)、プロトコル =
  `prompts/ecosystem-research-protocol.md`、`--safe-mode` で `~/.claude` の CLAUDE.md / rules / skills /
  plugins / hooks / MCP を外す (2026-09-21 probe: `-p` と `--append-system-prompt-file` は safe mode でも
  有効)。**safe mode は permissions を外さない** — user settings の `defaultMode: auto` も project settings も
  効くので、境界は repo line と同じく deny で書く。ecosystem line は deny に
  `Edit(state/<line>/.claude/**)` / `CLAUDE.md` / `.mcp.json` (cwd が model-writable で、cwd 直下の
  `.claude/settings.json` は project settings として翌朝読まれる) と `Read(~/.claude/**)` / `Read(~/.codex/**)` を
  足す。schema は ecosystem line の `repos` / `context_files` を拒否する。書き込み許可・receipt
  gate・4 内容状態・lint・呼2・metrics は repo line と同一コード。run は毎回 2 経路 — A = watchlist
  (`state/<line>/watched-sources.md` の 8 列表: 名前 / canonical URL / 種別 / 初出日 / last-attempt /
  last-seen / 最後に報告した意味のある変化 / 状態) の差分確認、B = watchlist に無い候補の広い探索 — を
  両方実行し、重複は topic 名でなく「前回報告後の変化」で判定する (問い単位の履歴は共通)。watchlist は
  model が保守する markdown で parser を持たない
- **問い粒度の履歴 (ADR-0017)**: 過去テーマの dedup は topic でなく問いで判定する —
  同じ問い + 同じ答え = 再選定しない / 同じ問い + 新しい証拠 = 更新してよい /
  同じ topic + 別の問い = 可。`past_topics.json` の entry は `question` と
  `answer_scope` を持つ
- **repo は read-only を三層で強制**: doctrine (プロトコル文言) + 書き込み先指定 +
  permission 層 (`--allowedTools` の Write/Edit を vault / state / past_topics の
  絶対パスに制限 + `--disallowedTools "Bash,Task,NotebookEdit"`)。**allow は加算リストで
  あって制限ではない** — `~/.claude/settings.json` の `defaultMode: "auto"` 下では
  列挙外の Bash が denial ゼロで通った (2026-08-22 PoC)。無人実行の境界は deny で書く
- **鮮度が一級制約**: LLM 界隈の知識は 1 週間スケールで陳腐化する。全 claim に
  as-of 日付、機会メモの全機会に失効日 (valid-until / 無効化イベント) を必須化
- **レポート存在ゲート (ctl-015、receipt 駆動)**: 各担当 line の成否は run スコープの
  receipt で決定論判定する (per line) — receipt 無し・不正な receipt は失敗、
  `article` / `brief` は当日の `{date}_{track}_*.md` が vault に存在することを要求、
  `quiet` / `hold` はファイル無しで成功。receipt が quiet/hold なのに run スコープの
  記事がある場合は記事を優先し (file wins)、`mismatch` として計上する。quiet/hold で
  `reason_code = fetch_failed` または web 検索 0 回のものは `quiet-suspect` として別計上
  (line 失敗にはしない)。日次の final_class は全 line 成功 = OK / 一部失敗 = E_PARTIAL /
  全滅 = E_NO_REPORT (ADR-0011 の分割を維持。`E_NO_REPORT` = 「ゲートを通った line が
  無い」)。失敗は line を明示して非ゼロ exit。呼2 の失敗はゲートに影響しない
  (fail-open — その line は `unverified` として計上し通知に出す)
- **自己改善ループ (ADR-0006、preserve)**: 毎朝の run を `metrics.jsonl` (gitignore)
  に永続記録 (呼1 は pass2 = 全 line・全 attempt の合算、呼2 は clarity_pass = ran/ok +
  実測、pass1 は None、fallback_used はリトライ発生の意味、試験 seam の run は
  `source: "test"` で記録され expect-check / dr-review の集計から除外)。加えて
  `line_states {article, brief, quiet, hold, mismatch, suspect, unverified}` と
  `verification {supported, partial, unsupported, unverifiable, edits, lines_verified}`
  を毎日記録する (ADR-0017)。決定論レポート lint (ctl-016、hard fail のみ
  即日 notify) は固定 2 節 (機会メモ / ソース) を検査し `body_chars` を残す — 本文の
  記述規律の質は人間 consumer が判断。消費は対話 skill `/dr-review` (週 1 目安)。効果を意図した変更
  commit には `DR-Expect:` trailer。**事後採点の LLM judge は復活させない** —
  eval は run 内で verdict が消費される in-loop 型に限る (ADR-0010。呼2 の原典照合は
  採点ではなく原稿の訂正であり、集計されるのは照合結果の内訳だけ)
- **7:00 morning brief は廃止 (ADR-0009)**: 毎朝の Slack 承認リクエストが全ノートを
  「返答待ち todo」化していたため retire。期限付き機会はノート末尾の「機会メモ」を
  読むときに拾う (代替通知は意図的に作らない)
- **`--append-system-prompt-file`** を使用（`--system-prompt-file` ではない）。
  Claude Code のデフォルト能力を保持するため
- **`--allowedTools`** で最小権限: 呼1 は WebSearch, WebFetch, Read, Glob, Grep +
  path 制限付き Write/Edit、呼2 は Read, WebFetch + 対象ノートと `runs/{date}.verify.json`
  だけの Edit。**`--disallowedTools`** で Bash 等を deny (呼1 / 呼2 共通。呼2 は
  WebSearch も deny — 照合は原典の再取得だけで行う)。
  `--dangerously-skip-permissions` は使わない。呼2 の allowedTools に埋めるノート名は
  basename 検証済みのものだけ (カンマ入り slug でルール注入できるため)
- **`< /dev/null`**: 全 `claude -p` 呼び出しで stdin をリダイレクト
- **オーケストレーションは shell**、JSON/TOML 解析は stdlib python3
  (`scripts/lib/dr_pipeline.py`)。pip 依存はランタイムに導入しない

### 設定ファイル

- `config.toml` と `past_topics.json` は個人データのため `.gitignore` に含まれる
- Git に含まれるのは `config.example.toml` と `past_topics.example.json`
- 設定を変更する場合は `config.toml` を直接編集する（example は公開テンプレート）
- 1 日あたりの本数は `[general] lines_per_day`（int ≥ 1、違反は fail-fast）、呼2 の
  モデルは `[verification] model`（既定 `sonnet`）で変える
- `state/`（brief / pending / watched-sources / playbook / runs）も運用 private で gitignore

### レポート出力

- 出力先: `{vault_path}/{output_dir}/{date}_{track}_{slug}.md`（flat dir — ctl-015 /
  ctl-016 / wiki ingest が前提にする）
- **本文は自由形式で固定見出しを置かない** (ADR-0009 / ADR-0017)。記述規律 3 点
  (冒頭は外部の出来事から / 初見の読者向けの背景 / 全 claim に as-of 日付と
  source の主張・推論・含意の分離) と文体規律 6 項目 (プロトコル Step 5、ADR-0015) を
  課す — 正本は `templates/report-template.md`。frontmatter は
  `kind: article|brief` と `question:` を持ち、長さは article が本文 3,000 字以内で
  材料に応じて短く、brief が 300〜600 字。line は `[tracks.<x>].template` で構成を
  上書きできる (省略時は共通テンプレ、読めないパスは実行時に既定へ fallback —
  ADR-0015。現在 edge が `templates/report-template-edge.md` を使用)
- 固定節は末尾 2 つのみ (ctl-016 の機械検査対象): **機会メモ**（日付付き締切を持つ
  機会だけを 何を / どこで / 失効日 / 判定 source / 更新条件 の 5 行定型で。正本は
  state の `pending.md` でここは読者向けの抜粋。無い日は「なし」）と
  **ソース**（最低 5 件、全 URL run 内解決済み）。ctl-016 の検査は非対称: `## ソース`
  不在と出典 URL 0 件は hard fail、`## 機会メモ` 欠落 (`ARTICLE_SECTIONS` はこれ 1 つ) と
  出典 < min_sources・本文 < 1,500 字は soft。`kind: brief` の note は機会メモと
  文字数の soft 検査を免除する
- **repo は read-only 参照のみ**。deploy・台帳更新はしない — note は読み物であって
  deploy ではない。取り込みは運用者が repo セッションで gate を通して行う

### プロンプト編集時の注意

- `prompts/repo-research-protocol.md` がリサーチの質を決める中核ファイル
  (目的関数・step 構成・問いの選定と 4 内容状態・receipt と根拠ファイルの書式・
  失効規律の正本)
- `prompts/ecosystem-research-protocol.md` は ecosystem line の呼1 の正本 (ADR-0018)。repo 版の姉妹版で、
  **共有契約 (receipt 形式・根拠ファイルの表・4 内容状態・末尾固定 2 節・完了報告) は両方を同時に直す** —
  `tests/test-daily-research.bats` が両ファイルに同じ assertion を当てる。プロトコルは mode の汎用品として
  書き、特定エコシステムの固有名 (Jev 等) は config の `focus` / `sources` と `state/<line>/` に置く。
  既存 line 用のプロトコル・テンプレートに ecosystem 向けの文言を入れない
- `prompts/verification-protocol.md` は呼2 の正本 — Step A の clarity (欠陥検出限定)
  が先、Step B の原典照合が最後。照合では根拠ファイルの全 claim を WebFetch で
  取り直し、数値・範囲・比較対象・話者を原典に合わせて訂正する (合わせられなければ文を
  削る)。取得できない source は本文を触らずソース節の該当行に `(未解決 {日付})` を
  付ける (ソース節への唯一の許可編集)。新事実の追加・frontmatter / 機会メモの変更・
  全面書き直しは禁止
- `templates/report-template.md` は記述規律と固定 2 節の定義。**固定節の見出しを
  変えるときは ctl-016 の検査 (`dr_pipeline.py` の `ARTICLE_SECTIONS` = 機会メモ、および
  `## ソース` の別建て hard check) を必ず同期する** — per-line テンプレート
  (`templates/report-template-edge.md` 等) にも固定 2 節は同じ形で必要
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
- **輪番 window + 4 内容状態 + 検証パス (ADR-0017)**: 毎朝、`akc` / `contemplative` /
  `aap` / `authorship` / `ans` / `desire` / `edge` の 7 line から連続 3 本を選んで実行する
  (7 日で各 line が 3 回)。`edge` も輪番の中にある。その後に daily の ecosystem line `jev` が 1 本走り、
  1 日 4 本になる (ADR-0018。輪番の本数・順序・位相と `lines_per_day` の意味は不変)。呼1 = Opus 研究 (問いの選定込み)、
  呼2 = 検証 + clarity (既定 sonnet)。ライン数・repo マッピング・輪番順・本数は
  config.toml から動的取得。ADR-0017 は ADR-0016 による per-repo 設計の退役を取り消し、
  ADR-0013 の daily edge 枠を終える — ADR-0008 / 0009 / 0010 / 0014 / 0015 は再び有効。
  **2026-08-22 にレポートを「動向解説 + repo への含意」へ単純化 (ADR-0014)**: 対立的
  フレーミング (裏付け禁止 / 反証義務 / 前提挑戦パス / theme_rank / scoring_criteria) を
  プロトコル・テンプレート・config の 3 層から撤去
- **所要時間とコストの目安** (4 line の見積もり。3 line 時代の実績値を 4/3 倍したもので未実測): 逐次実行して
  典型 35〜45 分、最悪ケースは 05:00 から約 260 分。コストは 1 日 $16〜20 (呼1 ≈ $4〜5/line、
  呼2 ≈ $0.5〜1/line。quiet / hold の line は呼2 が走らない)
- 蓄積層: Obsidian vault の LLM-wiki (ingest は Pass 3 で継続) + line 別 state
  (brief / pending / watched-sources / playbook / runs)。中央 graph.jsonld は凍結アーカイブ
