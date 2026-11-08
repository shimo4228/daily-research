# daily-research

Claude Code 非対話モード (`claude -p`) と macOS launchd で毎朝 5:00 に自律リサーチを実行し、前提知識ゼロで
読める解説ノートを Obsidian vault へ書くシステム。line の種類は 2 つ:

- **per-repo line**（`mode = "repo"`、既定）: 研究 repo 1 つに接地し、cwd = その repo で走る。repo に関係する
  外部の動向を 1 つ問いの形で選ぶ（ADR-0008 / ADR-0014）。輪番 window で毎朝 `[general] lines_per_day` 本
- **ecosystem line**（`mode = "ecosystem"`）: 接地 repo を持たず、cwd = `state/<line>/` で外部の変化そのものを
  観測する（ADR-0018）。`daily = true` で輪番の外に毎朝走る。広域 line はこの形（ADR-0019）

line の一覧・repo 対応・focus は各自の `config.toml`（私的）が正本で、
`python3 scripts/lib/dr_pipeline.py tracks config.toml` が出す。この文書には line 名も本数も書かない
（`tests/test-docs.bats` が検査する）。

## どこを見るか

| 知りたいこと | 正本 |
|---|---|
| 毎朝の流れ（輪番・呼1 / 呼2 / 呼3・gate・metrics） | `scripts/daily-research.sh`（各ブロック直上のコメント） |
| 呼1・呼2・呼3 の起動フラグ・ツール集合・deny・timeout | 同 script の呼び出し箇所（呼3 は `audit_call`）と `CALL1_TOOLS` / `CALL2_TOOLS` / `AUDIT_TOOLS` / `DISALLOWED_TOOLS` |
| モデルが書いてよい場所 | 同 script の `WRITE_PATHS` 配列（allow 規則とプロンプトの「書き込み先」節を描く） |
| JSON / TOML の契約（receipt・past_topics・billing・lint の対象節） | `scripts/lib/dr_pipeline.py` の定数と docstring |
| 調査と執筆の手順・4 つの内容状態・文体規律 | `prompts/repo-research-protocol.md`・`prompts/ecosystem-research-protocol.md` |
| 呼2（clarity + 原典照合） | `prompts/verification-protocol.md` |
| 呼3（照合監査の 2 段。置き換えの規則・状態ファイル） | `prompts/audit-protocol.md`・`prompts/audit-confirm-protocol.md`、`scripts/lib/dr_pipeline.py` の「呼3」節 |
| ノートの記述規律と末尾固定 2 節 | `templates/report-template.md`（line 別は `[tracks.<x>].template`） |
| 設定キーと既定値 | `config.example.toml` |
| 課金経路と支出（当月の実績） | `scripts/lib/billing.sh`、`./scripts/check-auth.sh` の出力、`state/api-spend.jsonl`（私的） |
| 運用の手順（launchd・トラブルシュート） | `docs/RUNBOOK.md` |
| テスト・lint の入口 | `.claude/verify.sh`（選定記録は `.claude/verify.md`） |
| 判断の経緯 | `docs/decision-history/`（索引は `docs/decision-history/README.md`） |
| 改善の基準値と判定 | `docs/plans/` の各 plan と `docs/plans/research/` |

## Build / Test / Run

```bash
# 手動実行（セッション内の Bash からも可 — lib/env.sh が CLAUDECODE を unset する。
# 呼1 は長いので background + 長め timeout で）
./scripts/daily-research.sh

# 試験 seam（試験 run は metrics に source: "test" で残り、集計から外れる）
DR_FORCE_TRACK=<line> ./scripts/daily-research.sh   # 当日の輪番 window 外でも指定 1 line を今日の日付で
DR_ONLY_TRACK=<line> ./scripts/daily-research.sh    # 当日担当 line のうち指定 line のみ
DR_DATE=YYYY-MM-DD ./scripts/daily-research.sh      # 輪番とレポート名の日付を固定

./scripts/check-auth.sh        # [billing] の経路で実 API を 1 回叩く（api モードは当月支出も出す）
.claude/verify.sh              # 全体 (lint + bats + pytest)。--staged は commit 境界用
```

## 規約（実物から導けないもの）

### 無人実行の境界

- **境界は deny で書く。** `--allowedTools` は加算リストで、user settings の `defaultMode: auto` 下では列挙外の
  Bash が通った（2026-08-22 PoC）。呼び出しは `--permission-mode default` を付け、書き込みは `Edit(//abs)` 規則で
  許す（`Write(path)` 規則は consult されない）。外した書き込み先は deny にも置く
- **全呼び出しは `--safe-mode`**（ADR-0019）。user の hook と CLAUDE.md が外れるので、hook が守っていた場所と
  資格情報の置き場は `DISALLOWED_TOOLS` の Read deny で塞ぐ。safe mode でも permissions は効く
- **repo は read-only。** 呼1 の書き込みは vault のレポート dir と line の state の一部だけ。note は読み物で、
  repo への取り込みは運用者が repo セッションで行う
- 呼3（照合監査、ADR-0020）のモデルは書き込みの道具も Read も WebSearch も持たない。候補の URL はノートに書かれた
  URL に限り、prompt に埋めるノート由来の文字列は呼び出しごとの乱数の区切りで挟む。ノートの置き換えは両段が確定し、
  第 2 段が置き換え文を訂正と認めた候補だけを `dr_pipeline.py audit-apply` が規則で行う。script だけが書く state の
  置き場（`pre-verify/`・`audit/`・`pre-audit/`）は呼1・呼2 の deny に置く（`SCRIPT_STATE_DENY`）
- `past_topics.json` はモデルに書かせない — gate 成功後に `dr_pipeline.py past-topics-append` が receipt から追記する
- 全 `claude -p` 呼び出しは `< /dev/null`。`--append-system-prompt-file` を使う（既定の能力を残すため）。
  呼2 の allow に埋めるノート名は basename 検証済みのものだけ
- 実行形は `mode` で決まり、line 名でコードを分岐させない（`tests/test-daily-research.bats` が検査）

### ノートと評価

- 本文は自由形式で固定見出しを置かない。固定節は末尾の **機会メモ**（日付付き締切の機会だけ）と **ソース** の 2 つで、
  ctl-016 lint（`dr_pipeline.py` の `ARTICLE_SECTIONS` と `## ソース` の hard check）が検査する。見出しを変えるときは
  lint と line 別テンプレートを同時に直す
- 提案・承認要求・「すべき」・手順列挙は書かない。使い道は平文で書く（ADR-0009 / ADR-0014）
- 材料が薄い日の quiet / hold は正常な結果。全 line quiet の日も成功
- 事後採点の LLM judge は入れない。eval は run 内で verdict が消費される型に限る（ADR-0010。呼2 の照合と呼3 の監査は原稿の訂正）。
  集計は決定論の `metrics.jsonl` と対話 skill `/dr-review`。効果を意図した変更の commit には `DR-Expect:` trailer
- 鮮度が一級制約: 全 claim に as-of 日付、機会メモの全機会に失効日

### プロンプトの編集

- 2 つの呼1 プロトコルは共有契約（receipt 形式・根拠ファイルの表・4 内容状態・末尾固定 2 節・完了報告）を持つ。
  片方を変えたらもう片方も直す（`tests/test-daily-research.bats` と pytest の `RECEIPT_KEYS` 検査が両方に当たる）
- ecosystem プロトコルは mode の汎用品として書き、特定エコシステムの固有名は config の `focus` / `sources` と
  `state/<line>/brief.md` に置く。repo 用のプロトコル・テンプレートには ecosystem 向けの文言を入れない
- プロンプトとテンプレートは日本語

### 設定と私的データ

- `config.toml`・`past_topics.json`・`state/`・`metrics.jsonl`・`logs/` は私的で gitignore。tracked なのは
  `config.example.toml` などの example だけ。設定は `config.toml` を直接編集する
- `state/<line>/brief.md` は運用者が書く静的な文書で、モデルは読むだけ（ADR-0019）
- ランタイムは bash + stdlib python3（3.11 以上、homebrew の `/opt/homebrew/bin/python3`）+ coreutils `timeout`。
  pip 依存をランタイムに入れない。pytest / ruff は dev 専用（`.venv`・`uvx`）
- bats の否定 assertion は `tests/test_helper.bash` の `refute_grep` で書く（`! grep` は set -e の対象外）
- `graph.jsonld` は凍結アーカイブ（ADR-0008）。vault の wiki が symlink で読むので残す

### 過去に試したもの

過去の提案と実測は `docs/decision-history/` にある。似た形を提案するときは、当時の実測を並べて示す:

- concept-graph 駆動の 2 パス選定 — 運用 4 日で出力が「外部研究が framework を裏付ける」survey 調に収束し、
  選定が graph の gap 埋めに縮退した（ADR-0008）
- LLM-as-Judge の事後採点（6 次元ルーブリック × Opus judge）— スコアを消費して行動を変える下流が無かった
  （ADR-0006 / ADR-0010）
- 自由探索 line と cluster 反発 — 出力がユーザーの関心から構造的に遠ざかり続けた（ADR-0004 / ADR-0007。
  広域 line は反発の機構を持たない別の実行形、ADR-0019）
- 7:00 の Slack 承認ブリーフ — 初の定時実行（2026-08-05）が 5 ノート・8 件の手を承認リクエストとして送り、
  承認キュー化した（ADR-0009）
- エージェントチーム版と Mem0 MCP（git history）
