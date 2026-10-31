# Plan: レポートの質とコスト（report-quality-and-cost）

- 起点: grill-me（2026-10-31、運用者）。根拠の束: [research/2026-10-31-report-quality-and-cost.md](research/2026-10-31-report-quality-and-cost.md)
- 実行者: 本セッション（Opus 5.5 = build-tier）が実装する。plan のレビューは Fable（judge-tier、運用者の指示）
- 状態: 承認済み（2026-10-31、運用者）
- 行番号は 2026-10-31 の作業ツリー。略記: SH = `scripts/daily-research.sh`、PY = `scripts/lib/dr_pipeline.py`、
  dr = `tests/test-daily-research.bats`、e2e = `tests/test-e2e-mock.bats`、py = `tests/dr_pipeline_test.py`

## Context

運用者の不満は 2 つ。(1) 問いの選定がいまの関心からずれ、同じ題材に戻る。(2) 費用。調査の結論:

- ずれと繰り返しの機構は、モデル自身が書き足す宿題（brief の「開いた問い」、事例日記と化した
  watched-sources）と、狭い repo 領域を週 2〜3 回掘る飽和。2026-09-14 以降の live 30 run で quiet / hold は 0。
- 費用は呼1 が 85%。呼び出しごとに約 6 万 token の土台（ハーネス + cwd の CLAUDE.md ≈ 4 万、未使用ツール
  定義 ≈ 2.3 万）が乗り、line 費用の約 3 割を占める。run ごとの記帳（playbook・watched-sources・1 MB の
  past_topics.json）がターンと出力を食う。

目標: per-repo の問いを運用者の関心に近づけ、広い領域の line を戻して 5〜6 月の面白さを取り戻し、
月の API 支出を約半分以下へ下げる（実数は `.notes/cost-2026-10-31.md`（私的））。レポートの読み物としての質（呼2 の照合・記述規律）は保つ。

## 決定事項（grill-me 2026-10-31、運用者）

| # | 決定 | 根拠（research の節） |
|---|---|---|
| D1 | 構成: 広域 line `wide`（ecosystem mode、範囲「AI 時代の考えと手段」= 道具・製品、開発の実践、研究、使い方の文化）を毎日 1 本 + per-repo 輪番を 1 日 1 本（`lines_per_day = 1`）。jev line は廃止 | §3, §6 |
| D2 | 呼1・呼2 とも `--safe-mode` + `--tools <必要な組み込みツール>`。repo の CLAUDE.md / AGENTS.md は Step 3b（選定後）で明示的に Read する | §1, §2 |
| D3 | playbook への追記をやめる。brief は主題・読者に既知の前提・参照箇所だけの静的な文書にし、モデルは編集しない（「開いた問い」を撤去、待ちの問いは hold が書く pending.md だけ）。repo line の watched-sources 巡回と記帳をやめる。ecosystem line の watchlist は残す | §3, §4 |
| D4 | 記帳をコードへ: past_topics.json への追記は receipt から orchestrator が行う。（根拠ファイルの表を絞る案は Fable の指摘で取り下げた — 費用への効きは 1% 未満で、supports / limits / contradicts 列が Step 5 の「反対材料」「主張と推論の分離」を claim 単位で強制する唯一の場所） | §4 |
| D5 | 直近の repo 活動を line brief に注入する。初版は 14 日分の commit 件名だけ（ADR / RFC の題の抽出は G3 で関係づけが浅いと出たら足す）。問いの候補のうち 1 件以上を関係づけるが、選ぶのは自由。いまの作業の裏付けでなく、運用者がまだ知らない外部の展開を探させる（効かせ方は推奨案を既定とした — 運用者の明示回答なし） | §3 |
| D6 | 簡素化は出力を変えない範囲（未使用コード・文書の重複）。プロトコル本文の減量は対象外 | §5, §7, §8 |
| D7 | フィードバックループ（読者メモ・既知文献の注入・採用率の選定への還流）は入れない。採用検出は pipeline の外の事後集計として残す | §6 |
| D8 | 呼1 は Opus、呼2 は Sonnet のまま。subscription 課金モードは残す | — |

運用者の回答（2026-10-31、plan 作成中）:

| 問い | 回答 |
|---|---|
| 導入時期 | でき次第すぐ。jrp 側の desire-loop 試行（config.toml:116、11-03 の run まで）を待たない |
| jrp との config 共有 | 導入前に切り離す |
| 作業ツリーの未コミット変更 | テストを通して単独で commit |
| 判定方法 | 観測数のゲートに組み替える（「導入と判定」） |

## Fable レビューの反映（2026-10-31）

| 指摘 | 反映先 |
|---|---|
| 必須 1: safe-mode で user の Read hook（episode-log ブロッカー）が外れるのに、`~/.claude`・`~/.codex` の Read deny が ecosystem line（SH:317-318）にしか無い | WP-B commit (1): 両 deny を共通の deny へ移し、呼1・呼2 の全 line に効かせる |
| 必須 2: ecosystem プロトコルとテンプレートの判定基準が OSS・release 向けで、`wide` の「考え・実践・研究・文化」を拾えない | WP-C commit (5): 該当箇所を「実装・製品」と「考え・実践・研究」の条件付きに汎化。何を変化と数えるかは `state/wide/brief.md` に置く |
| 必須 3: worktree では私的ファイルを要求する bats の環境検査が落ち、「branch で verify.sh 緑」が成立しない | P0-4: 環境検査を「私的ファイルが無い checkout では skip」にしてから branch を切る |
| 推奨 4: 根拠ファイル 6 列化は費用に効かず質を落としうる | D4 の後半を取り下げ |
| 推奨 5: 書き込み許可の縮小はプロトコル側の state 撤去と同じ commit に置く | commit の分け方（WP-B (2)(3)） |
| 推奨 6: テスト影響の見落とし 4 件と dr:70-75 の意味の取り違え | WP-B・WP-C のテスト項目 |
| 推奨 7: 書き込み先の契約に正本が無い | SH に書き込み先の配列を 1 つ置き、allow とプロンプトを同じ配列から描く。プロトコルは指すだけ |
| 推奨 8: API key の env file が Read で読める | WP-B commit (1): `[billing] env_file` の親 dir の Read を共通 deny に。P0-5 の後に `check-auth.sh` |
| 推奨 9: D5 は commit 件名だけで始める | D5 |
| 推奨 10: G1 の閾値の境界域を事前に決める | G1 |
| 任意（採用分） | Probe を 3 ターンの書き込み試験に / past-topics-append の細部 / 注入行の `#` 除去 / G2 の位相 / archive からの復元 / G1 から試験 run を除く / ゲート 1 の code block 除外と line 名検査 / ADR 注記の形式 / watchlist は「1 run 8 件」だけ / 呼2 の自己完結の確認 / G3 に pending.md の行数 |

## 正本と参照（stale を防ぐ設計）

原則: **事実ごとに正本を 1 つ決め、他の文書は値を書かずに正本を指す**。値を書く必要がある箇所は、
機械ゲート（テスト）で正本と一致させる（検出はコード、判断は人間）。

| 事実 | 正本 | 他の書き方 |
|---|---|---|
| line の集合・repo 対応・focus | 各自の `config.toml`（私的。tracked な正本は無い） | line の種類だけを書く。一覧は `python3 scripts/lib/dr_pipeline.py tracks config.toml` で出す |
| 輪番の本数・daily・支出上限・呼2 のモデル | `config.example.toml` のキーと説明、値は `config.toml` | キー名で指す（「本数は `[general] lines_per_day`」）。値を書かない |
| 呼1・呼2 の起動条件（フラグ・timeout・max-turns・ツール集合） | SH の呼び出し箇所と直上のコメント | 1 行の要約 + 参照 |
| モデルが書いてよい場所 | SH の書き込み先の配列（mode 別）。`--allowedTools` の Edit 規則とプロンプトの「書き込み先」節をこの配列から描く | プロトコルは「タスクプロンプトの『書き込み先』節のパスだけ」と指す。パスを列挙しない |
| 解析の契約（receipt・past_topics・billing・lint 対象節） | PY の定数と docstring | 参照のみ。プロトコルが示す receipt の形はテストで定数と一致させる |
| 調査と執筆の手順・内容状態・文体規律 | `prompts/*.md`、`templates/*.md` | 1 行の要約 + 参照 |
| 判断と経緯 | `docs/adr/` | ADR 番号で指す。CLAUDE.md に経緯を書き写さない |
| 費用の実績 | `state/api-spend.jsonl`・`metrics.jsonl`（私的）、`check-auth.sh` が当月支出を表示 | 文書にドル額を書かない（`.claude/skills/dr-review/SKILL.md:127-128` の既存方針と同じ）。見積もりが要る判断は ADR に as-of 日付付きで残す |
| テスト・検証の手順 | `.claude/verify.sh`（P0 で新設） | コマンドを書き写さず参照 |
| ディレクトリ構成 | ツリーそのもの | CLAUDE.md は「どこを見るか」の短い索引だけ |
| `graph.jsonld` | 凍結アーカイブ（ADR-0008）。repo 外に読み手がいるので残す | 1 行 + ADR-0008 |
| 改善の基準値 | research §6 と `docs/plans/research/adoption_backtest.py` | plan / ADR はリンク |

機械ゲート（`.claude/verify.sh` から走る）:

1. **値の書き写し検査**（WP-D、`tests/test-docs.bats` を新設）: 対象は CLAUDE.md・README 英日・RUNBOOK 英日・
   CONTRIB 英日・llms.txt・SKILL.md・`.claude/skills/dr-review/SKILL.md`。fenced code block を除いてから、
   `lines_per_day = <数字>`・ドル額・1 日の本数の固定値で赤。加えて、`tracks config.toml` が返す line 名の
   backtick 付きの形（`` `akc` `` など）が対象文書に無いこと（config.toml が無い checkout では skip）。
   ADR・`docs/plans/`・`docs/design/` は日付付きの記録なので対象外。較正: 文書を直す前に、既知の箇所
   （CLAUDE.md:3, 280, 292、RUNBOOK.md:128, 354、README.md:13, 135、llms.txt:3、SKILL.md:11）で赤になり、
   shell の例で赤にならないことを確かめる。
2. **共有契約**（WP-B、pytest）: PY に `RECEIPT_KEYS`・`PAST_TOPIC_KEYS` を置き、両プロトコルの receipt 例と
   `past_topics.example.json` がそれと一致することを検査する。両プロトコルが `past_topics.json`・
   `playbook.md` を名指さないことも検査する。dr:340-361 の literal assertion（両プロトコルに同じ文字列を
   当てる形）と dr:325-332（example の 9 key）をこれで置き換える。

## 作業包

### P0 前提（main 上。実行時の挙動を変えない）

1. `docs(plan): happy-growing-bachman` — この plan・research report・`adoption_backtest.py` を単独で commit。
2. `.gitignore` に私的 config の退避の型（`config.toml.*`、`.backup/`）を足す。root に未追跡の
   `config.toml.*bak*` が 4 本あり、公開 repo に入りうる。中身は動かさない。
3. 前セッションの未コミット変更（`tests/test_helper.bash` 新設・bats 2 本・CLAUDE.md / CONTRIB の 1 行）を、
   `bats tests/` が緑のことを確かめて単独で commit。`test_helper.bash` を同じ commit に入れる（無いと dr / e2e の
   101 件が load で落ちる）。
4. 運用者の環境を見る bats（dr:163 config.toml、dr:180-195 plist、dr:213-221 logs と 700、dr:225-231
   past_topics と退避）を、私的ファイルが無い checkout では `skip` にする。環境の確認は `check-auth.sh` の役目で、
   コードの検査ではない。これで worktree でも verify が成立する。
5. skill `verify-bootstrap` で `.claude/verify.sh` を作る（選定は skill。少なくとも bats・pytest・ruff・`bash -n`）。
   承認は `verify_allow.py`（運用者が確認画面で通す）。以後の commit は verify-precommit hook がこれを通す。
6. jrp を専用 config へ切り離す。`config.toml` を jrp の既定の読み先 `~/.config/jrp/config.toml`（今は存在しない）へ
   写し（mode 600）、`~/.config/jrp/env:23` の `JRP_DAILY_RESEARCH_CONFIG` 行を消す（値は表示しない。
   `scripts/lib/billing.sh` はこの file から `ANTHROPIC_API_KEY` だけを読む）。直後に `scripts/check-auth.sh` で
   翌朝の run が key を読めることを確かめる。続けて daily-research の `config.toml` から jrp 専用の
   `[tracks.claude-code]`（:187）と読み手の無い `[user_profile]`（:178）を消す。どちらも退避を先に取る。

### WP-B コストと記帳（feat。worktree の branch `feat/report-quality-cost`）

main の作業ツリーは導入まで触らない — launchd の 05:00 run は main の作業ツリーをそのまま実行する。
worktree では `.venv` を作り直す（`uv venv && uv pip install pytest pytest-cov`）。

0. ADR-0019（skill `adr-writer`、adr-reviewer 込み）を branch の最初の commit に。D1〜D5・D7 と運用者の回答を
   記録し、旧 ADR の該当節に adr-writer の dated Note（`> **注記（YYYY-MM-DD, ADR-0019）**`）を残す:
   ADR-0008（repo の CLAUDE.md の自動読込前提、watched-sources・playbook を含む run 構造）、ADR-0010 の
   Decision 4（呼2 を safe-mode なしで走らせたトレードオフ — safe-mode がプラグインの無効化を兼ねる）、
   ADR-0017（`lines_per_day` の運用値、brief の開いた問い）、ADR-0018（jev daily line、:174-182 の hook と
   呼2 の記述）。分け方は adr-writer の When to Use に従う。
1. Probe（commit しない）: 新しいフラグ集合で haiku を 3 ターン、session の subscription で走らせる。「許可した
   path に 1 件、外に 1 件書け」と指示し、前者が通り後者が拒否されること、モデルが答えるツール一覧が集合
   どおりであること、土台の token 数を記録する。
2. **commit (1) 境界: safe-mode・tools・Read deny**
   - 呼1（SH:419-430）: `--safe-mode` を mode 分岐（SH:312）から全 line 共通へ移し、`--tools "$CALL1_TOOLS"`
     （WebSearch,WebFetch,Read,Glob,Grep,Edit,Write）を足す。
   - 呼2（SH:614-624）: `--safe-mode --tools "$CALL2_TOOLS"`（Read,WebFetch,Edit,Write。Write は verify.json の
     新規作成に要る — `prompts/verification-protocol.md:57`、SH:600 が事前に消す）。SH:589-591 の注記を書き直す。
   - `Read(//HOME/.claude/**)`・`Read(//HOME/.codex/**)`（今は SH:317-318 の ecosystem だけ）と、`[billing]
     env_file` の親 dir への Read を、共通の deny（SH:58 の `DISALLOWED_TOOLS`。env file の分は `billing_load`
     （SH:106）の後に足す）へ移し、呼1・呼2 の全 line に効かせる。ecosystem 固有の cwd 設定面の deny
     （SH:314-316）は据え置く。
   - テスト: `CALL1_TOOLS` / `CALL2_TOOLS` に Bash が無いことを新しい assertion で（dr:70-75 は「allowedTools に
     無条件の Write/Edit を入れない」検査なので `--tools` には当てない）。e2e:1286 を反転（repo line にも
     `--safe-mode`）し、`.args_*` で `--tools` を検査。e2e:1287 の厳密一致と e2e:1273-1279 を新しい共通 deny に。
   - 呼2 は safe-mode で daily-research の CLAUDE.md（記述規律の要約。ADR-0010 Decision 4 が前提にした）を
     読まなくなる。`prompts/verification-protocol.md` の Step A が自己完結しているかを見比べ、足りなければ
     `templates/report-template.md` を指す 1 行を足す。
3. **commit (2) past_topics をコードへ**
   - SH に書き込み先の配列（mode 別）を置き、`ALLOWED_TOOLS` の Edit 規則（SH:398-401）とプロンプトの
     「書き込み先」節（SH:372-380）をこの配列から描く。配列から `past_topics.json` を外す（SH:380 の指示も消える）。
   - `past-topics-append`（PY の新コマンド、TDD）: 入力は receipt・gate が解決した report の basename・track・date。
     entry は読み手 `cmd_past_themes`（PY:334-386）が使うキーに絞る: `{date, track, title, slug, question,
     answer_scope}`。file が無ければ `{"version": 1, "topics": []}` から作る。title と answer_scope は receipt の
     reason と同じく制御文字を除いて長さを切る。同じ dir の一時ファイルへ `ensure_ascii=False` で書いて
     `os.replace`。既存の JSON が壊れていたら書かずに非ゼロ（run 開始時の退避 SH:143-147 が残る）。receipt の
     欠けた項目は空文字 + WARN。line の成否には効かせない。呼ぶ位置は gate 成功後（SH:567 付近）、`for ROW` の
     中で次の line の past-themes（SH:339）より前。quiet / hold も記録する。名前は dr:281-289 の `past-themes*`
     照合に掛からない。
   - receipt に `answer_scope` と `title` を足す（両プロトコルの Step 5.5 相当）。`receipt-read` の 4 列 TSV
     （PY:487）は変えない — SH:524-526 の分割と py:1066・1132・1148 が前提にしている。
   - 両プロトコル: 大原則 1（repo :17-18 / eco :21-23）を「書き込み先はタスクプロンプトの『書き込み先』節の
     パスだけ」に、Step 6.5 の past_topics の記帳を外す。`past_topics.example.json` を新しい entry の形に。
     既存 595 件は触らない。
   - テスト: e2e の mock が自分で past_topics に追記する処理（e2e:218-230, 271）を外し、mock receipt に
     answer_scope / title を足す（e2e:1230）。dr:73・e2e:513 を「past_topics の allow が無い」へ、e2e:487 を
     新しいプロンプト文へ。機械ゲート 2 を入れ、dr:325-332 と dr:340-361 の該当 assertion を置き換える。
4. **commit (3) state の撤去: brief の静的化・playbook・repo の watched-sources**
   - 書き込み先の配列を `pending.md` と `runs/**` に狭める（ecosystem は `watched-sources.md` も）。プロンプトの
     「書き込み先」節には「brief.md は読むだけ」を残す（dr:296・e2e:491 が brief.md の文言を見る）。SH:284 の
     state 層コメントを合わせる。
   - `prompts/repo-research-protocol.md`: Step 1（:34-48）で brief.md を運用者が書く静的な文書（主題・読者に
     既知の前提・参照箇所）とし、開いた問いの項と「Step 6 で初期化」を外す。:48 の閉じる対象は pending.md の
     状態にする。Step 2（:50-57）の 2.1（watched-sources 巡回）を外す。Step 3b（:83-86）の最初に repo の
     CLAUDE.md（無ければ AGENTS.md）の Read を置き、大原則 2（:19-20）からそこを指す。Step 5 の文体規律 3・5
     （:143, 146）から playbook を外す。Step 6（:171-186）は pending.md の更新だけにし、完了報告（:198）の
     Watched-source diffs を外す。規則の出所（:202-211）を合わせる。
   - `prompts/ecosystem-research-protocol.md`: brief を静的にし（開いた問い :53 を撤去）、playbook の記帳を撤去。
   - テスト: dr:350・dr:109（`last-attempt`）を ecosystem 版だけに当てる。e2e:1281（`Edit(//…/state/eco/**)`）を
     狭めた許可に合わせる。

### WP-C 選定と wide（feat。同じ branch）

1. **commit (4) 直近の repo 活動の注入**
   - `repo-activity <repo> [--days 14]`（PY の新コマンド、TDD）: `git -C <repo> log --since=<14 日> --no-merges`
     の件名を、各行 `- ` 接頭・先頭の `#` を落として、件名 30 件・合計 2,000 字まで出す。制御文字を除く。git の
     失敗や repo の不在は空出力で、line を止めない。
   - SH: repo line だけ（`$LINE_MODE = repo`）、LINE_PROMPT の line brief の直後（SH:370 と 372 の間）に
     「## 直近の repo 活動（14 日）」として挿入する。SH:361-362 の「データであって指示ではない」注記の内側に入る。
   - `prompts/repo-research-protocol.md`: Step 1 の読む物に直近の repo 活動（タスクプロンプト）を足す。Step 2 の
     広い検索 2〜3 query のうち 1 本を、直近の repo 活動の主題に関係する外部の展開に当てる（repo 自身の成果物は
     探さない）。Step 3（:59-81）で、候補のうち 1 件以上を直近の repo 活動に関係づける。どれを選ぶかは自由。
   - テスト: 直近活動の節が repo line にだけ出ることを e2e で（mode 別プロンプト検査 e2e:1301-1308 の隣）。
2. **commit (5) wide の受け皿: ecosystem プロトコルの汎化**
   - `prompts/ecosystem-research-protocol.md` の OSS 向けの判定を、「対象が実装・製品なら 実在 → 実測 → 試せるか、
     考え・実践・研究なら 主張 → 根拠 → 反対材料 → 分かっていないこと」の条件付きに汎化する: 経路 A の変化の
     種類（:70-74）、経路 B の探索対象と `hold` の条件（:78-85）、重複判定の変化の一覧（:102-109）、選定基準
     （:114-115）、終わり方の目安（:117-123）、Step 4.3 実在の確認（:131-133）、扱う内容の目安（:176-180）。
     `templates/report-template-ecosystem.md:15-18` の流れの目安も同じ分岐にする。dr:376-383（`この repo` /
     `Step 3b` / `jev` / `typesafe` を入れない）を守る。
   - 経路 A の確認は 1 run 8 件まで（last-attempt の古い順）。watchlist の行数の上限は G1 の line 別費用を見てから。
   - `config.example.toml`: `lines_per_day = 1`（:6。コード既定 PY:56 と :4 のコメントに合わせる）。構造は
     dr:318-323・413-430 が固定しているので変えない。
   - テスト: dr:55 の line 名ガードに `wide` を足す。ecosystem の watchlist 検査（dr:363-384・398-411）が通ること。

### 導入（WP-B・WP-C が揃った日の日中）

1. branch で `.claude/verify.sh` が緑、Code Review と security-reviewer を通ったら、main へ ff-only で取り込む
   （push はしない）。
2. main の checkout で私的な設定を変える（どちらも退避を先に取る）:
   - `config.toml`: `[tracks.jev]`（:163）を消し、`[tracks.wide]`（`mode = "ecosystem"`、`daily = true`、
     focus = 「AI 時代の考えと手段」の 4 領域、sources = 情報源の種類の示唆）を足す。`lines_per_day = 1`。
   - state: 各 line の `brief.md`・`playbook.md`、repo line の `watched-sources.md`、`state/jev/` を
     `state/_archive/2026-10-31/` へ移す（gitignore 下なので移動が唯一の退避）。repo line の brief は開いた問いを
     除いた静的版を置く。既存の開いた問いは pending.md へ移さない（宿題を別の名前で再生産しないため）。
   - `state/wide/brief.md` は実装者が草稿を書き、運用者が導入前に読む。4 領域それぞれで何を変化と数えるかを
     ここに書く（関心の定義は運用者の持ち物）。
3. 試験 run 2 本（API 課金、line 2 本分）: その日の live run が走っていない repo line 1 本（同日の receipt と
   根拠ファイルを上書きしないため。10-31 なら edge）と `wide` を、それぞれ `DR_FORCE_TRACK` で。**この plan の
   承認を、この 2 本と P0-6 の `check-auth.sh`（実 API を 1 回叩く probe）の実行の承認とする。** 追加の run は
   都度聞く。確認項目は Verification。
4. 翌朝 05:00 の run が新構成の初回。desire の `daily = true` は config.toml:116 のコメントどおり 11-03 の run の
   後に外す（それまでは 1 日 3 本、以後 2 本）。jrp は分離後の写しを読むので影響しない。

### WP-A 掃除（refactor。導入の後）

1. skill `refactor-clean` を `scripts/`・`tests/` に回す。読み手の棚卸しは `.claude/skills/` まで含める
   （dr-review が `metrics-backfill`・`report-lint`・`wiki-quality-scan`・`expect-check` を使う、research §8）。
   読み手が 0 のものだけ消す。
2. `graph.jsonld` と `docs/graph-schema.md` は残す。vault の `wiki/graph.jsonld` がこの file への symlink で、
   skill `wiki-harvest` が `track` 値を読む。ADR-0008 の plan（`docs/plans/cached-zooming-goose.md:116-118`）も
   「削除しない」。文書側の記述を 1 行に縮める（WP-D）。

### WP-D 文書（導入の後。skill: context-sync / readme-writer の Incremental / llms-txt-writer）

1. 機械ゲート 1 を先に入れ、現行の文書で赤になることを確かめる（較正）。
2. CLAUDE.md（context-sync）: 「どこを見るか」の索引と、実物から導けない規約だけを残す。値・line 一覧・本数・
   ドル額・ツリー全体を消して正本を指し、経緯は ADR 番号で指す。D2 の後、CLAUDE.md はどの `claude -p` にも
   ロードされず（呼2 が唯一の読み手だった、SH:590-591）、読み手は対話セッションだけになる。
3. README 英日（readme-writer の Incremental）: line の種類（per-repo 輪番 + 広域 1 本）を値なしで書き、ドル額と
   本数を消す。リンクを付け替える: RUNBOOK `#cost`（README.md:13）、llms-full.txt（:86, 96, 111）。課金の記述の
   食い違い（:135 の Max plan と :13 の api）を解く。
4. RUNBOOK 英日: 運用者が手を動かす節（launchd の操作・トラブルシュート・check-auth）を残し、構成の説明・
   Initial Setup の重複（README の Quick start が正）・費用の実数を消す。:49 の launchd ラベルを plist に合わせる。
   file は残す（外部記事からのリンクがありうる）。
5. CONTRIB 英日: 試験 seam と line の足し方を残し、ツリーとテスト手順は実物と `.claude/verify.sh` を指す。
   file は残す。
6. llms.txt（llms-txt-writer）: 入口の索引に直す。llms-full.txt（42 KB の全文複製で、すでに 4 か所古い）は
   削除し、README・llms.txt:9・CLAUDE.md:64 の参照を付け替える。
7. `SKILL.md` と `.claude/skills/dr-review/SKILL.md`: 書き写した値（本数・モデル・上限・節）を正本への参照に
   する。dr-review の振る舞いは変えない。
8. `docs/adr/README.md` の索引に ADR-0019 があることを確かめる（adr-writer が足す）。

## Review chain（skill: implementation-chain）

| 包 | 種別 | TDD | Code Review | Security Review | Refactor Clean |
|---|---|:-:|:-:|:-:|:-:|
| P0-4・5 環境検査の skip・verify.sh | chore | - | Y（ゲートの設定） | - | - |
| WP-B | feat | Y（past-topics-append） | Y | Y（無人実行の権限境界・書き込み先・safe-mode で外れる hook の代替） | - |
| WP-C | feat | Y（repo-activity） | Y | Y（repo 由来の文字列を LLM 文脈へ入れる経路を足す） | - |
| WP-A | refactor | - | Y | - | Y |
| WP-D | chore / writing | - | 機械ゲート 1 のテストだけ | - | - |

- Code Review は built-in `/code-review` を effort `medium` で、reviewer への指示（correctness と要件に効く gap
  だけを報告）を添える。WP-B・WP-C は security-reviewer と並列に起動する。
- 各 commit の前に Verify（`.claude/verify.sh` と `git status`）。
- commit (1)〜(5) はそれぞれ単独で revert できる。どの commit の後でも「プロトコルが書けと言う場所 = SH の
  書き込み先の配列」が一致する。

## Verification

- `.claude/verify.sh`（bats・pytest・ruff・`bash -n`）が main と worktree の両方で全件緑。
- Probe（WP-B 1）: 新フラグで起動でき、ツール一覧が集合どおり、許可外の Write は拒否、土台の token 数を記録。
- 試験 run 2 本:
  - receipt と note が揃って gate を通り、呼2 が verify.json を書く（unverified にならない）
  - ログに tool の不在・permission 拒否のエラーが無い
  - `past_topics.json` が JSON として読め、2 件増え、既存の件数が変わらない
  - result JSON の usage で、cache 書き込みとターン数が同じ line の直近 live run より減っている
  - `state/api-spend.jsonl` の line 費用（呼1 + 呼2）を記録する
  - repo line の完了報告と根拠ファイルで、直近活動に関係する候補と Step 3b の CLAUDE.md の Read を確かめる
  - wide の `watched-sources.md` が 8 列の表で作られ、記事が「考え・実践・研究」の側の材料も扱える形になっている
- 導入後は G1〜G3（次節）。

## 導入と判定（観測数で開くゲート）

interview では「2 週後に印象、6 週後に採用率 15% 以上かつ引き直し率 10% 未満」と決めた。基準値を判定と
同じ定義（21 日窓）で取り直すと per-repo は採用 19%・引き直し 16% で、per-repo 1 本/日の 6 週（n ≈ 42）
では 95% 信頼区間の半幅が ±15 pt になり、この閾値は誤差と区別できない。measurement-discipline の原則 2
（暦でなく観測数で開く、n を事前に決める、14 日で決めきる）に沿って次へ組み替えた（運用者承認 2026-10-31）。

| ゲート | 開く条件（観測数） | 判定 | 予想日 |
|---|---|---|---|
| G1 コスト | 新構成の live line-run が 10 件（試験 run は支出台帳の `ts` で除く） | 支出台帳の line 平均（呼1 + 呼2）を、導入前の live line 平均（基準値、`.notes/cost-2026-10-31.md`（私的））との比で判定: 65% 以下は合格（11-03 以後の 2 本/日で月の支出が約半分以下）。65〜75% は合格扱いで、次は `--max-turns` と経路 A の確認数を詰める。75% 超は commit (1) が効いていないので、Probe の土台 token と実 run の cache 書き込みを突き合わせる。合格したら上限（呼1 / 呼2 / 日 / 月）を観測の最大値を基に下げる | 導入から約 4 日 |
| G2 中間 | 輪番の全 line が 1 回ずつ（現 config で 6 本。11-03 に desire が輪番へ戻ると位相が飛び、6 日より延びうる） | 運用者が読み、明らかに悪い部品だけ個別に revert する | 約 6〜8 日 |
| G3 継続判定 | per-repo 14 本 + `wide` 14 本 | 運用者の判断（line 別に「ずれ / 繰り返し / 良い」）。生の数字として引き直し件数（当日判定できる）、窓が閉じた分の採用件数（`adoption_backtest.py`）、`pending.md` の行数の推移（hold が新しい宿題帳になっていないか）を添える。14 日目に必ず決める | 約 14 日 |
| 参考 | G3 の 14 本目から 21 日後 | 採用率の確定値を記録する（合否には使わない） | 約 35 日 |

edge は採用が最も多い line（12 / 25）なので、G2・G3 で個別に見る。落ちていたら edge だけ巡回を戻す。

## 失敗モードと戻し方

| 失敗モード | 検出 | 戻し方 |
|---|---|---|
| 直近活動の注入で、いまの作業の裏付けを探す記事が増える（ADR-0008 の収束） | G3 の引き直し件数、運用者の判断 | commit (4) を revert（候補 1 件の義務だけ外す選択もある） |
| safe-mode で repo の CLAUDE.md が自動で入らず、含意が repo の前提とずれる | 試験 run の完了報告、G2 | Step 3b の Read 指示を強める。最後の手段は呼1 の safe-mode だけ外す（Read deny は残す） |
| `--tools` か書き込み許可の不足で run が崩れる | Probe、試験 run のログ、receipt ゲート | 集合と配列を足す |
| past_topics.json のコード追記で 1 MB の JSON を壊す | pytest（壊れた入力・原子的置換）、追記後の JSON 読み込み | run 開始時の退避（SH:143-147）を戻す |
| state の撤去を戻したい | G2 | commit (3) を revert し、`state/_archive/2026-10-31/` から brief・playbook・watched-sources を戻す（state は git 外） |
| repo の commit 件名に指示文が混ざる（prompt injection） | security-reviewer | 制御文字と行頭 `#` の除去・上限・データ注記の内側に置く。書き込み先が狭く、harness と key の Read は deny なので、被害は vault と state に閉じる |
| `wide` が関心から離れる（ADR-0007 の失敗の形） | G3 | brief と focus の文言を直す（反発の機構は入れない） |
| `wide` の watchlist が膨らみ費用が増える | G1 の line 別費用、watchlist の行数 | 行数の上限をプロトコルに足す |
| edge の採用が落ちる | G2・G3 | edge だけ巡回を戻す |

## やらないこと

- フィードバックループ（D7）と、プロトコル本文の減量（D6）
- 根拠ファイルの表の削減（D4、Fable の指摘で取り下げ）
- jrp の Jev による候補選別と、執筆役の分離（Web 全体の発見を削るため）
- モデルの格下げ、subscription モードの削除（D8）
- `--restricted` への切替と、Read を path で絞る境界の作り直し（境界の書き方を変えるので別 plan の候補。
  この plan は harness・codex・key の file の Read deny だけを足す。research §2）
- `graph.jsonld` の削除（repo 外に読み手がいる。移すなら vault と wiki 系 skill の側の plan）

## 文書と実物の食い違い（WP-D で解く。実物が正）

| 文書 | 記述 | 実物 |
|---|---|---|
| CLAUDE.md:3, 280 | 1 日 3 本、`contemplative` を含む 7 line | `config.toml:17` は `lines_per_day = 2`、contemplative の track は無い |
| CLAUDE.md:281、README.md:135、llms-full.txt:15 | jev は daily line、1 日 4 本 | jev は 10-19 から輪番（config.toml:163-166）、desire が 11-03 まで daily（:116-120） |
| CLAUDE.md:292、RUNBOOK.md:354、README.md:13 | 1 line の費用の見積もり | 実測より 3〜5 割高い（research §1） |
| llms.txt:3、SKILL.md:11、RUNBOOK.md:128 | `lines_per_day` の既定は 3 | コードの既定は 1（PY:56、config.example.toml:4）。example の値は 3（:6） |
| README.md:135 | Max plan、key は unset | 運用は api（README.md:13、CLAUDE.md:289） |
| CLAUDE.md:56、llms-full.txt:27, 182 | bats 3 本 | 4 本（test-billing.bats を含む） |
| RUNBOOK.md:49 | `launchctl start com.daily-research` | plist の Label は `com.yourname.daily-research` |
| RUNBOOK.md:354、README.md:13 | 費用の実数 | dr-review SKILL.md:127-128 は「公開 doc に実数を含めない」 |
| vault の CLAUDE.md:156-162・AGENTS.md:154-160（repo 外） | graph-schema は自動再生成で常に最新 | 2026-08-04 から凍結（ADR-0008） |

## 運用者が push 前に決める点

- llms-full.txt の削除（外部記事からのリンクは repo から確かめられない）
- この plan と research report に載せた費用の実数（`.claude/skills/dr-review/SKILL.md:127-128` は公開 doc に
  コストの実数を含めない方針）
- README の line の書き方（種類だけか、研究 repo へのリンクを並べるか）
