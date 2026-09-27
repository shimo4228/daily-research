# daily-research を per-repo 輪番方式へ戻し、リサーチ方法を再設計する（2026-09-14）

## Context

- 著者決定（2026-09-14）: ADR-0016 の discovery 号（repo 文脈を渡さない自由探索）は「無関係な話題ばかり」。8 月中旬までの per-repo リサーチライン方式へ戻す。1 日 3 本を 7 line（akc / contemplative / aap / authorship / ans / desire / edge）の輪番で。探索はもう少し発散させる。edge の毎日枠は外す。「面白さ」を採点する評価は設計しない（memory `feedback_subjective_eval_trap`）。
- 著者決定（同日、追加）: 2 本のディープリサーチが「構造として変えろ」と言った 6 点を**すべて一括で**入れる。旧 pipeline の骨格に prompt 規則を載せるだけの案は不採用。
- discovery 号は commit 7877a11 として main に保存済み。復元元は commit 56b0bfb（2026-08-27、ADR-0015）。旧 live config は `.notes/reorg-baseline/2026-09-06/config.toml`。
- 根拠: `deep-research-result-claude-2026-09-14.md` / `deep-research-result-codex-2026-09-14.md`（引用 arXiv 24 本の実在を照合済み）。採る交点:
  - 単一 agent を軸（Kim et al. arXiv 2512.08296: 逐次課題で multi は 39〜70% 悪化）。repo 文脈は渡す。第 8 の自由ラインは作らない。7 line 輪番は残す（反応なしで bandit 報酬が無い）。
  - **内容状態**: 通常記事 / 短報 / 更新なし / 保留 を正常な結果にし、「毎回新テーマを十分な長さで完結」を捨てる。
  - **短い line brief** を最初に渡し、選定後に repo 詳細を読む。台帳の open task を選択条件にしない。
  - 過去テーマ履歴を **問い粒度**へ（同じ問い + 同じ答え = 禁止 / 同じ問い + 新証拠 = 更新可 / 同じ topic + 別の問い = 可）。
  - **根拠ファイル**（時点・locator・条件・反対材料・出所系譜・取得状態）と、**原典を再取得して照合する fresh-context の別 pass**。検証結果は metrics へ。
  - **機会メモの正本を state** に置き pending / resolved / contradicted / expired / unverifiable の状態を持つ。
  - 問い生成パスだけ定型を外す（Price of Format, arXiv 2505.18949）。視点変更 1 つ + 未使用観測からの問い 1 つ。停止規則 =「次の検索が何を解決するかを言えなくなったら止める」。
  - **本文は固定見出しなし**、上限 3,000 字で材料に応じて短く。末尾の 2 節（機会メモ / ソース）だけ固定。
  - 呼2 は clarity を先、原典照合を最後（照合後の主張に自由編集を置かない）。

## 探索で確定した事実（実装の制約）

- **vault 消費者** `daily_wiki_ingest.sh`: ファイル名契約 `^\d{4}-\d{2}-\d{2}_[A-Za-z0-9_-]+\.md$` のみ。frontmatter は `wiki_index.py` が `tags` だけを読む（維持必須）。複数本/日は対応済み。x-draft は `{date}_{track}_{slug}.md` 前提（復元で整合）。
- **56b0bfb の pipeline**: `rotation-pick`（dr_pipeline.py:196-225）= `day % N` で 1 行 + daily 行。per-line loop（daily-research.sh:220-426）は N 行対応済み。`$PAST_THEMES` は loop 前に 1 回（:130）。呼2（:382-401）= `Read,Edit(//<note>)`、sonnet、15 turn、900 s、fail-open、metrics `CLARITY`。slug 検証 :355-365（allowedTools へのカンマ注入対策、維持）。`STATE_DIR` は `else` 内で代入（:230）→ hoist が必要。retry skip は report の有無だけ（:295）。`report-lint`: hard = `## ソース` 無し / URL 0、soft = URL < 5 / `## 機会メモ` 無し / 全体 < 1500 字。日次 class OK / E_PARTIAL / E_NO_REPORT。bash 3.2 の `-nt` は秒精度 → run スコープは `find -newer "$LOCK_DIR/pid"` を使う。
- **実測**（08-13〜09-05）: 呼1 ≈ $4.1〜4.7/line、turns p50 42 / p90 48（cap 55 に 1 回）、5〜8 分。呼2 ≈ $0.47、1.5〜3 分。3 line 典型 25〜35 分、最悪 195 分（05:00 → 08:15）。
- **tests**: pytest の rotation 2 件は K=1 で位相不変（無改変で通る）。e2e mock は rotating 2 line で `lines_per_day` を入れない。静的 bats は template の `この repo への含意` と e2e の prompt grep が固定見出し前提 → 変更。`.claude/verify.sh` は無く、検証 = `bats tests/*.bats` + `pytest`。
- **auto mode**: allow は加算。呼2 から WebSearch を除くには `--disallowedTools`。
- **ADR 様式**: Status / Date / Context / Decision / Review-when / Alternatives Considered / Consequences。index は `docs/adr/README.md` の表。新 ADR は 0017。past_topics.json は discovery 号に触られていない（復元不要）。

## 実装手順

### Step 0 復元と整理
- `git checkout 56b0bfb -- scripts/daily-research.sh scripts/lib/dr_pipeline.py scripts/lib/auth.sh prompts/ templates/ tests/ pyproject.toml CLAUDE.md README.md README.ja.md SKILL.md config.example.toml docs/ llms.txt llms-full.txt .claude/skills/dr-review/SKILL.md`（HEAD は python 駆動なので merge でなく全復元）。
- `git rm`: scripts/lib/discovery.py、prompts/discovery-protocol.md、prompts/editorial-protocol.md、tests/discovery_test.py、tests/fixtures/discovery-mock-claude、reader-profile.example.md。`docs/adr/0016-*.md` は残す。`.gitignore` の `reader-profile.md` 行は残す。`rm -rf state/discovery`。
- `cp .notes/reorg-baseline/2026-09-06/config.toml config.toml`。

### Step 1 config（`config.toml`、`config.example.toml`）
- `[general] lines_per_day = 3`。`[tracks.edge]` の `daily = true` を削除（template は残す）。`[verification] model = "sonnet"`。`[user_profile].goal` を 3 line に。example の輪番説明を window 方式に、`kind` は frontmatter の項目である旨のコメント。

### Step 2 `scripts/lib/dr_pipeline.py`
- `_load_tracks`: `lines_per_day` 検証（bool 除外、int ≥ 1、違反は ValueError で fail-fast）。任意: track 名を `^[A-Za-z0-9_-]+$` に制限。
- `cmd_rotation_pick`: `k`、`n`、`start=(day*k)%n`、`rotating[(start+i)%n] for i<min(k,n)`、daily 行は後置。K=1 は旧位相と同一。ヘッダコメント更新。
- `cmd_past_themes`: 見出しを問い単位の 3 分類規則へ。各行 `question`（無ければ title）+ ` — answer_scope`。inclusion filter を `title or question`。
- 新 `cmd_receipt_read <path> <date> <track>`: JSON object、`status ∈ {article, brief, quiet, hold}`（厳密）、`date`/`line` は在れば一致必須、`report` は null/"" か `^{date}_{track}_[A-Za-z0-9._-]+\.md$`、article/brief は report 必須、`reason` は tab/改行を潰し 200 字。stdout `status\treport\treason`、不正は rc 1。
- 新 `cmd_verify_read [path]`: `{supported, partial, unsupported, unverifiable, edits}` を int ≥ 0 で正規化（bool 除外、欠損 / 破損は零 + `ran:false`）、常に rc 0、1 行 JSON。
- 新 `cmd_config_get <config> <section.key> [default]`。
- `cmd_metrics_append`: `STATE\t<track>\t<status>[\tmismatch]` → `line_states {article, brief, quiet, hold, mismatch}`（常に出す、零も）。`VERIFY\t{json}` → `verification`（5 key 合算 + `lines_verified` = ran の数、無ければ None）。CLARITY / clarity_pass は互換のため据え置き。backfill は新 field を None にし解析しない。
- `cmd_expect_check`: `quiet_rate`（quiet+hold / 全状態）、`receipt_count_min`、`unsupported_rate`（unsupported+partial / 全 verdict）、`clarity_ok_rate`。`report_count_min` は残す（vault 件数の意味）。
- `cmd_report_lint`: frontmatter `kind:` を読み（無ければ article）、`brief` は `## 機会メモ` と文字数の soft を免除。`MIN_BODY_CHARS=1500`（全体長、article のみ）は据え置き。`ARTICLE_SECTIONS` 無変更。結果に `kind` を含める。

### Step 3 `scripts/daily-research.sh`
- helper: `find_run_file <dir> <name>`（`-newer "$LOCK_DIR/pid"`）、`find_run_reports`、`find_run_receipt`。
- loop 冒頭で `STATE_DIR` を hoist、`RECEIPT_PATH="$STATE_DIR/runs/${DATE}.json"`、`VERIFY_PATH="$STATE_DIR/runs/${DATE}.verify.json"`、`mkdir -p "$STATE_DIR/runs"`。`PAST_THEMES` を loop 内で再計算。`VERIFY_MODEL` を config-get で取得。
- pick ログを全 line 列挙 `Rotation pick: a, b, c (ADR-0010/0017)` + `Today's lines: N`。
- 呼1 prompt の書き込み先: 1) vault `${DATE}_${TRACK}_{slug}.md`、2) `$STATE_DIR`（brief.md / pending.md / watched-sources.md / playbook.md / runs/${DATE}.md 根拠 / runs/${DATE}.json receipt 必須）、3) past_topics.json。allowedTools は無変更（`Edit(//${STATE_DIR#/}/**)` が覆う）。
- retry skip: report **または** run スコープ receipt があれば retry しない。
- **gate（旧 ctl-015 を receipt 駆動に）**: receipt 無し → line 失敗。`receipt-read` 不正 → 失敗。article/brief で run スコープの report 無し → 失敗（証拠なき完了）。quiet/hold で run スコープ report あり → WARN して article 扱い（file wins、`mismatch` を計上）。hold で pending.md 空 → WARN。通過した line は `Line <T> state: …` と `Line <T> report gate passed` をログ、`STATE` 行を metrics へ。呼2 は `CLARITY_NOTE` が空でない（article/brief）ときだけ。
- 呼2: `--append-system-prompt-file prompts/verification-protocol.md`、`--allowedTools "Read,WebFetch,Edit(//<note>),Edit(//<verify.json>)"`、`--disallowedTools "$DISALLOWED_TOOLS,WebSearch"`、`--max-turns 30`、`--model "$VERIFY_MODEL"`、`CLAUDE_TIMEOUT=1200`（30 turn + WebFetch は 900 s に収まらない）。prompt に原稿パスと verify.json パス。終了後 `verify-read` で 1 行 JSON にして `VERIFY` 行を metrics へ、`VERIFY <T>: {…}` をログ。ラベル `Clarity` 系は据え置き。
- 日次まとめ: `Line states: article=N brief=N quiet=N hold=N (今朝: a, b(brief) / 更新なし: c(hold))` をログ。通知: OK かつ公開あり `今朝のリサーチレポートが完成しました (今朝: … / 更新なし: …)`、全 quiet `今朝は更新なし (更新なし: …)`、E_PARTIAL `リサーチが一部失敗しました (今朝: … / 更新なし: … / failed: …)。ログを確認してください。`、E_NO_REPORT は従来文。class 判定ロジックは無変更（全 line quiet の日は OK、`E_NO_REPORT` = 「gate を通った line が無い」と dr-review SKILL に注記）。
- 呼1 timeout 1500 / 55 turn は据え置き。

### Step 4 呼1 prompt `prompts/repo-research-protocol.md`（全面改稿。各規則に出所を 1 行で添える）
- **役割と目的関数**: 「この line の読者が今朝知る価値のある外部の出来事を 1 つ、問いの形で選び、原典で確かめ、記事・短報・更新なし・保留のいずれかで正直に終える」。発見ノルマなし。
- **Step 1 文脈読込（短く）**: `brief.md`（主題 / 開いた問い 1〜3 / 読者に既知の前提 / repo 参照箇所。無ければ Step 6 で config の focus と context_files から初期化）、過去の問い履歴（past-themes 出力）、`pending.md`、自己シグナル。**context_files はここでは読まない**。日付と現在も有効かを先に見る。
- **Step 2 差分と広い探索**: watched-sources の差分（`last-attempt` / `last-seen` を分けて記録）は入力の一つ。短く広い検索 2〜3 query で「外部で何が起きたか」を見る（Anthropic: start wide then narrow）。同じ問いに同じ答えを書かない。
- **Step 3 問い候補の列挙（定型なし）**: 自由記述で 3〜6 件、各候補は問いの形（対象 / 知りたい関係 / 条件）+ 想定 answer_scope。1 件は視点変更（当事者 / 状況=失敗・撤退 / 言語・地域 / 隣接）、1 件は Step 2 で見つけたが本題に使わなかった観測から。各候補に「既に答えられている度合い」「一次ソースに届く見込み」。選定は「答えが分かっていない度合い」優先、「使い道」は 2 番目でゲートにしない。**材料が薄ければここで quiet / hold を選んでよい**（hold は pending.md に問いと再開条件を書く）。
- **Step 3b**: 選定後に関係する ADR / 台帳 / 文書だけ Read し含意の前提を確認。
- **Step 4 リサーチ**: 主要 claim ごとに SIFT（発信者と利害 / 独立した別報道 / 原典まで、転載は独立証拠に数えない）。停止 =「次の検索が何を解決するかを言えない」+ 補助（独立 3 源 / 直近 2 検索が同内容 / 上限）。同じ転載が続けば機関・言語・資料種別を 1 回変える。原語検索 1 回。「探索範囲内で見つからなかった」と書き「先行例なし」と断定しない。abstract だけを本文確認済みと言わない。
- **Step 4b 根拠ファイル** `runs/${DATE}.md`: claim ごとに `claim_id / proposition（本文と同じ数値・語）/ source_url・title / published_at・accessed_at / locator / evidence_type / supports・limits・contradicts / origin_group / provenance / fetch_status`。
- **Step 5 執筆**: article は本文 ≤ 3,000 字で材料に応じて短く、brief は 300〜600 字（frontmatter `kind: brief`）。**固定見出しなし**。第一文は外部の出来事、一文一命題、括弧注記 2 箇所まで、内部文書は中身を 1 行要約、repo の自己紹介は 2 文まで。流れの目安 = 外部の出来事 → 仕組み・比較・反対材料 → 分かった範囲と分かっていないこと → repo との接点（段落で、見出しにしない）。含意は条件付き（ICD 203 の estimative language）、「今すぐ X すべき」へ変換しない。source の主張 / 分析の推論 / repo への含意を文の形で分ける。末尾の `## 機会メモ`（pending.md からの抜粋、article のみ必須）と `## ソース`（WebFetch 解決済み URL のみ）。
- **Step 5.5 receipt**: 記事を書いた直後に `runs/${DATE}.json` `{date, line, status, report, question, reason}` を書く（timeout で receipt が無いと失敗扱いになるため、state 更新より先）。quiet/hold は記事を書かず receipt と reason だけ。
- **Step 6 state 更新**: `brief.md`（開いた問いを delta 更新）、`pending.md`（状態 pending / resolved / contradicted / expired / unverifiable、判定 source、更新条件、期限。expired は「検討期間が過ぎた」）、watched-sources、playbook（delta + superseded、各行に 世界の根拠 / 操作上の観測 / 暫定判断 を 1 語）、past_topics.json（schema を明示: `{date, track, title, slug, question, answer_scope, keywords, summary, opportunities}`）。
- 完了報告に `State:` `Question:` `Claims tabled:` を追加。加えない規則: 必ず N source / 必ず反対意見 / 必ず斬新 / 毎回行動提案 / 過去 30 日 topic 全禁止 / 面白さ採点。

### Step 5 呼2 prompt `prompts/verification-protocol.md`（`git mv clarity-review-protocol.md` して書き直し）
- 役割: 研究文脈を持たない初見読者 + fact-checker。根拠ファイルとソース節の URL だけ WebFetch してよい。
- **Step A clarity（先）**: 56b0bfb の 7 つまずき種別 + span Edit。claim を含む文の数値・固有名詞・日付は触らない。
- **Step B 検証（最後）**（≤ 8 claim、優先 数値 > 引用 > 日付 > 固有名詞）: 各 claim を原典で照合 → supported / partial / unsupported / unverifiable。partial / unsupported は該当 span を原典に合わせるか「〜と報じられている」へ弱める（削るのは文まで）。unverifiable（取得失敗）は本文を触らず、ソース節の該当行に `(未解決 {date})` を付ける（ソース節への唯一の許可編集）。原文の該当箇所が見つからないときだけ不一致にする（CiteGuard）。自分の知識から URL・事実・数値を足さない。
- 最後に `runs/${DATE}.verify.json` `{supported, partial, unsupported, unverifiable, edits}` を書く。fallback: 根拠ファイルが無い → 本文の数値・引用付き claim ≤ 5 を inline link で照合。
- 禁止: WebSearch、新事実の追加、frontmatter / 機会メモの変更、全面書き直し、Bash。
- 完了報告 `## Verification + Clarity Complete`。

### Step 6 templates / example
- `templates/report-template.md`: frontmatter `date / category / kind / tags / topic / question / sources / actionable`、本文は自由形式（固定見出しなし、記述規律 3 点、article ≤ 3,000 字 / brief 300〜600 字）、末尾固定 `## 機会メモ`（3 行定型 + 判定 source + 更新条件、brief は省略可）と `## ソース`。edge template は同じ変更 + `kind: article`。
- `past_topics.example.json` に新フィールド入りの例を 1 件。

### Step 7 tests
- fixture `tests/fixtures/config-lines-per-day.toml`（7 line、K=3、edge template、`[verification]`）。
- pytest 追加: rotation window（K3N7 で 7 日に各 3 回・同日重複なし・連続 mod N・冪等 / K>N / K1 位相不変 / daily 併用 / lines_per_day 検証）、past-themes の question 優先と規則文、receipt-read（4 状態、不正 status、非 JSON、カンマ / `/` 入り report、date/line 不一致、article で report null、reason サニタイズ）、verify-read（複数行 JSON → 1 行、欠損 → 零 ran:false、負値 / 文字列 / bool → 0）、metrics-append の STATE / VERIFY 集計と None、backfill の None、expect-check の quiet_rate / receipt_count_min / unsupported_rate / clarity_ok_rate、lint の `kind: brief` 免除、config-get。
- e2e mock: 呼1 mock が prompt から receipt パスを取り、`.state_<track>` seam（既定 article）で report + receipt を書き、past_topics に question 付き entry を追記、根拠ファイルを書く。呼2 mock が verify.json を書く。シナリオ追加: quiet / hold / receipt-missing（既存 noreport）/ receipt-article-no-file / receipt-quiet-with-file / receipt-bad-json / brief / verify-missing / stale receipt（`touch -t` で古い receipt + noreport → receipt missing）。restricted-tools test は WebFetch あり・WebSearch が disallowed・`state/` は verify.json の 1 件だけ。`lines_per_day=2` の window test（`Rotation pick: akc, authorship`、line 2 が line 1 の question を見る）。prompt test の `この repo への含意` grep を `kind:` / `run receipt` / `brief.md` / `pending.md` に置換。
- 静的 bats 追加: verification-protocol の存在と旧 protocol の不在 / 呼2 の allow・disallow・max-turns 30・config-get / past-themes が loop 内 / `PICKED_LIST` / receipt-read・verify-read・`runs/${DATE}.json`・verify.json・brief.md・pending.md・STATE・VERIFY の grep / template は `kind:`・`## 機会メモ`・`## ソース` あり、`^## 結論`・`^## この repo への含意` なし / config.example に lines_per_day と [verification]。

### Step 8 ADR-0017 と doc sync
- `docs/adr/0017-three-line-window-content-states-and-verification-pass.md`: Decision = 7 line K=3 window 輪番、edge daily 終了、4 内容状態と receipt gate、line brief / pending / 根拠ファイルの state、問い粒度の履歴、呼2 = clarity + 原典照合（verify.json → metrics）、本文は自由形式 ≤ 3,000 字、ADR-0016 Decision 5 の退役取消（0008〜0015 復活）。Review-when = 4 週後の /dr-review: `unsupported_rate`、`quiet_rate`（隠れ蓑化）、`clarity_ok_rate < 0.8`（14 日）、`receipt_count_min`、E_PARTIAL 頻度、`total_cost_mean > 18`。「面白さ」は判定に使わない。Alternatives = discovery 号継続 / 5 本/日 / 3 process 分離（Codex 案 II）/ orchestrator–worker / 段階導入（Claude 版推奨、著者が一括を選択）。
- index 行、0013・0016 に supersede 注記、0010 に window と呼2 役割変更の注記。
- doc sync: CLAUDE.md、README.md・README.ja.md、docs/RUNBOOK(.ja).md、docs/CONTRIB(.ja).md、llms.txt・llms-full.txt、.claude/skills/dr-review/SKILL.md（`E_NO_REPORT` の意味、新 metric 語彙、pass2 は 3 line 合算）、SKILL.md。
- commit trailer: `receipt_count_min >= 3` / `report_count_min >= 0`（外す）/ `total_cost_mean <= 18` / `pass2_turns_p90 <= 150` / `fallback_rate <= 0.15` / `lint_hard_count == 0` / `clarity_ok_rate >= 0.9` / `unsupported_rate <= 0.2` / `quiet_rate <= 0.5`。旧 `beb554a` の `total_cost_mean <= 13` は設計上 NOT_ACHIEVED になる旨を ADR に記す。

## 検証

1. `bats tests/*.bats` と `.venv/bin/python -m pytest`。
2. dry pick: `python3 scripts/lib/dr_pipeline.py rotation-pick config.toml 2026-09-15` → 3 行・重複なし（09-15: edge, akc, contemplative / 09-16: aap, authorship, ans / 09-17: desire, edge, akc）。
3. live 試走 `DR_FORCE_TRACK=akc bash scripts/daily-research.sh`（source=test、40 分見込み）。確認: log に `Line akc state: …`、`=== Clarity pass:`、`SUMMARY Clarity:` の searches > 0、`VERIFY akc: {… "ran": true}`、`Line states:`。vault の `2026-09-14_akc_*.md`（固定見出しなし、frontmatter に kind / question）。`state/akc/{brief.md, pending.md, runs/2026-09-14.md, runs/2026-09-14.json, runs/2026-09-14.verify.json}`。past_topics 末尾に question / answer_scope。metrics 末尾に `line_states` / `verification` / `source: test`。Pass 3 は今日の sentinel 済みなら skip で正常。
4. 2 本目の試走を edge で（template override）。可能なら 3 本目で quiet を意図的に出す line（材料の薄い line）を選び、receipt-only の経路を確認。
5. commit（git-workflow に従う）→ 翌朝 05:00 launchd（plist 無変更）。翌朝ログで `Rotation pick: a, b, c`、`Today's lines: 3`、`Line states:`、所要時間を確認。

## 既定として採る判断（変えるなら実装前に）
- 呼2 のモデルは sonnet で開始（照合の見逃しが目立てば opus へ）。呼2 timeout は 1200 s。
- receipt が quiet/hold なのに run スコープの記事がある場合は記事を優先（file wins、mismatch を計上）。article なのに記事が無い場合は失敗。
- 1 line 失敗時の exit 1 + error notify（E_PARTIAL）は据え置き。
- discovery 号のファイルは tree から削除（履歴に残る）。
- metrics のラベル CLARITY / clarity_pass は互換のため据え置き（呼2 の中身だけ変わる）。

## 外部意見（Astra / Codex gpt-6-astra high、Herdr pane w3F:p39、2026-09-14）— VERDICT: premise-hole

各 finding は主ループで検証済み。採否と、plan 本文へ反映した箇所を 1 行ずつ。全文は scratchpad `astra-plan-response.md`。

1. **REFUTE 採用**: 「短い文脈から始める」を復元する `line-brief`（dr_pipeline.py:307-311 が context_files を「Step 1 で必ず Read」として注入）と config の focus 文言（authorship「使い道が repo の文書・task に固有名詞で結べる動向を優先」等）が打ち消す。→ Step 2 に `line-brief` の出力変更（context_files を「選定後に読む候補」として別節に出す）、Step 1 に focus 文言の書き換え（「使い道優先」「repo に使える場合のみ」を削る）を追加。
2. **REFUTE 採用（言い換え）**: Price of Format（arXiv 2505.18949）は instruction tuning / inference の構造化テンプレートの実証で、候補列挙や見出し撤去の比較ではない。Claude 版も「執筆パスは定型を保つ」と言っている。→ 本文見出しの撤去は「著者が旧構造を冗長と判断」+ Codex 版「見出し名を強制しない」を根拠にした**編集判断**として記述し、論文を根拠にしない。問い生成の定型撤去も編集仮説。
3. **REFUTE 採用**: 不一致を「〜と報じられている」へ弱めても裏付けは生まれない（原典 10%・条件付き、原稿 50%・一般、の例）。「該当箇所が無いときだけ不一致」も誤り。→ Step 5 の検証規則を「数値・範囲・比較対象・話者を原典に合わせて訂正する。合わせられなければ文を削る。帰属表現への変更は、二次報道の主張であることが原典で確認できる場合だけ」に書き換え。
4. **MISSING 一部採用**: 呼2 が主張を訂正・削除しても past_topics / pending / receipt は訂正前のまま、呼2 timeout でも未検証版が公開・ingest される。→ 呼2 失敗 / verify.json 欠損は `unverified` として STATE・metrics・通知（「未検証: X」）に出す（silent にしない）。state は呼2 が触らない設計を維持し、「state は検証前の版」を ADR-0017 の既知の限界に明記。receipt を記事直後に書く順序（timeout で失敗扱いを避ける）は維持し、その間に timeout した run の state 未更新は playbook の次回 delta で吸収する（受容したリスク）。
5. **MISSING 採用**: 取得失敗と quiet / hold を区別できない。→ receipt に `reason_code ∈ {no_new_evidence, thin_material, fetch_failed, carry_over}` を追加。shell は 呼1 の result JSON の `searches` を読み、quiet/hold で `reason_code=fetch_failed` または `searches==0` なら `quiet-suspect` として別計上し通知に「取得失敗の疑い」を出す（line 失敗にはしない）。metrics `line_states` に `suspect`。
6. **MISSING 採用**: (a) `unsupported_rate` の分母から unverifiable を外し（(unsupported+partial)/(supported+partial+unsupported)）、`unverifiable_rate` を別に持つ。(b) verify.json は 呼2 前に `rm -f` し、読み取りは run スコープ（`-newer pid`）に限定。(c) verifier の見逃しは自己申告では測れない → 既知誤りを植えた固定 fixture（`tests/fixtures/verify-golden/`: 数値改変・話者違い・範囲の過大一般化・原典なし）を用意し、試走時と /dr-review 時に 呼2 を手動で当てて見逃し / 過剰修正を確認する（launchd には入れない）。
7. **MISSING 採用**: 資料を読んで問いを更新する往復が無い。→ Step 4 に「原典が問いの前提を崩したら、問いを撤回 / 言い換え / 分割してよい（1 回まで）。receipt の `question` は最終形、根拠ファイルに `question_revised_from` を残す」を追加。
8. **ALTERNATIVE 一部採用**: 通常記事を主要主張 3〜5 件に絞り全件照合する。→ 根拠ファイルの claim を 3〜6 件に上限し、呼2 は全件照合（「≤ 8 件・優先順位」を廃止）。長さは著者の判断待ち（上限 3,000 字で材料に応じて短く、を既定に据える。1,500 字案は著者が選べば 1 行で変えられる）。
- 総評（「語彙は取り込まれたが検証・記憶・完了の接続が薄い」）は妥当として受け、上の 4〜7 で接続を足した。三工程分離を採らない点と一括導入は著者判断のまま。

## plan 本文への反映（外部意見の採用分。上の Step に優先する）
- Step 1: config.toml / example の各 line `focus` から「使い道…を優先」「repo に使える場合のみ」等の選択条件文言を削り、主題の説明だけにする。
- Step 2: `cmd_line_brief` は name / focus / sources / self_signals を出し、context_files は「## 選定後に読む候補（Step 3b）」として別節で出す。`cmd_receipt_read` は `reason_code` enum も検証（無ければ `unspecified`）。`cmd_metrics_append` の `line_states` に `suspect` と `unverified`。`cmd_expect_check` の `unsupported_rate` 分母変更 + `unverifiable_rate`。
- Step 3: 呼1 結果 JSON から searches を取り（`log_summary` が既に読む `server_tool_use.web_search_requests`）、quiet/hold + (`fetch_failed` or searches==0) → `quiet-suspect`。呼2 前に `rm -f "$VERIFY_PATH"`。呼2 class != OK または verify `ran:false` → STATE に `unverified` を追加し通知に「未検証: X」。
- Step 4: Step 1 の「短い文脈」は line-brief の新出力 + brief.md + 問い履歴 + pending。Step 4 に問いの改訂規則。Step 4b の claim は 3〜6 件。receipt に `reason_code`。
- Step 5: Step B を「全 claim 照合、数値・範囲・比較対象・話者を原典に合わせて訂正、合わせられなければ文を削る、帰属表現への変更は二次報道であることが原典で確認できる場合のみ」に。
- Step 7: `tests/fixtures/verify-golden/` を追加（自動 test ではなく手動確認用。README に手順）。
- Step 8: ADR-0017 に「state は検証前の版」「見出し撤去は編集判断」「Price of Format は根拠にしない」を明記。trailer に `unverifiable_rate` を追加。
- 検証 3: 試走後に verify-golden で 呼2 を 1 回手動実行し、植えた誤りの検出数を記録。
