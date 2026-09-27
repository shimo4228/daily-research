# daily-research 再設計: per-repo in-context research への全面移行

## Context

著者の診断（2026-08-04、2 段階）:

1. **「GEO 研究の裏付け」化**: daily-research の authorship line（他 line も同傾向）が、
   framework を裏付ける survey 調の trivia を量産している。研究が「概念体系への寄与
   (reinforces / challenges / extends)」を目的関数にしており、**実践を前に進める手**を
   生まない。
2. **構造の根**: 現行 pipeline は各 repo を `.repo-graphs/*.jsonld`（概念体系のコピー）
   越しにしか見ない = **一段フィルター**。進めるべき価値を知っている文脈
   （CLAUDE.md・.notes/TASKS.md・manifesto open questions・project memory の ledger・
   同日改訂した inquiry-first Review trigger）は全部 repo 側にあり、pipeline から不可視。
   だから目的関数が「concept の補強」に縮退する。

著者提案: **リサーチを各 repo の中から直接実行する**。豊富な repo native コンテキストで
「進めるべき価値」を選定し、出力を「今すぐ実行可能な戦術」にする。

同日セッション前半で authorship-strategy 側は gap-review 収束ループを退役し
inquiry-first に改訂済み（skill / CLAUDE.md / memory）。本計画はその研究入力側の対応物。

追加指示（著者、同日 3 通目）:

3. **既存機構の並べ替えで設計しない** — 2026-08 時点の最新の知識オントロジー構築手法を
   search-first で外部照合してから設計を確定する（実施中: 2 本の web research agent —
   ①最新 KG/オントロジー構築・maintenance 手法、②autonomous research-agent pipeline
   の現行設計。orchestrator 内部調査と合わせ 3 本並走）。
4. **「LLM 界隈は 1 週間で陳腐化する」を global メンタルモデルとして常駐させる** —
   ハーネス global 層（rule）に書き込む。パイプライン設計自体にも鮮度・失効を
   一級制約として組み込む。

## 決定済み設計（著者 2 メッセージから確定、質問は不要と判断）

- **全面移行**: 4 line 全部を per-repo 実行へ。concept-graph 駆動のテーマ選定
  （.repo-graphs sync / coverage-report / cluster-report / reinforces スキーマ）は retire。
  残すと旧目的関数（graph の gap 埋め = 収束モデル）が復活するため。
- **出力先は vault のまま**: `{vault}/daily-research/{date}_{track}_{slug}.md`。
  問題は入力コンテキストであって出力先ではない。wiki ingest ループ・past_topics dedup・
  レポート存在ゲート (ctl-015) を無傷で維持。
- **新しい目的関数**: 「この line を今すぐ前に進める、実行可能な手を見つける」。
  裏付け (corroboration) は成果ではない。actionable な手が見つからない日は
  正直にそう書く（無理にひねり出さない）。

## 新メンタルモデル（プロンプトに書き込む中核）

1. **入力**: repo の運用状態そのもの — CLAUDE.md / AGENTS.md、.notes/TASKS.md、
   docs/manifesto.md の open questions、docs/empirical/implementation-log.md、
   （config で指定する）private ledger 等。graph は読んでもよいが選定基盤にしない。
2. **選定**: 「この repo の現在地から見て、今いちばん価値ある前進は何か」を先に立て、
   それを前に進める外部シグナル（新 venue / 新機構 / 新標準 / 期限付き機会 / 反証）を
   リサーチする。テーマは「文献」でなく「手がかり」。
3. **出力 genre**: actionable-tactics note —
   - リード: **今すぐ実行可能な手（1〜3 件）**: 各 = 何を / どこで / 具体手順 /
     所要目安 / repo 側 gate・doctrine 上の留意（gate 判定はしない — deploy 判断は
     repo セッションの領分）
   - 支持証拠（一次ソース、最低 5 件 URL）
   - 開いた問い（本当に新しいものだけ。repo の OQ 語彙に接続）
   - **禁止**: 「framework を裏付ける」を主旨とするノート。裏付けは付録であって主題にしない
4. **repo は read-only**: 現行不変。deploy・台帳更新はしない。ノートは提案であって
   deploy ではない（authorship の inquiry-first / gate-at-deploy と整合）。
5. **各 repo の doctrine 尊重**: 各 repo CLAUDE.md が宣言する禁止事項
   （authorship: マネタイズ提案禁止・self-created authority-record 禁止等）を
   プロンプトで明示的に尊重させる。

## 実装計画（Explore 調査で確定した詳細込み）

対象 repo: `~/MyAI_Lab/daily-research`

現行の正確な形（調査確定）: 単一プロセス 2-pass。cwd は daily-research 固定
（per-repo cwd / --add-dir は一切なし）。Pass 1 = Opus、prompt =
theme-selection-prompt + coverage-report + cluster-report + past-themes 連結、
出力 = テーマ JSON（`dr_pipeline.py validate-theme` が正規化・検証）。
Pass 2 = Sonnet、`--append-system-prompt-file prompts/research-protocol.md`、
30 分 timeout。後段に ctl-015（vault の `{date}_*.md` 存在ゲート、flat dir +
`-maxdepth 1` 前提）、ctl-016 lint、Pass 3 wiki ingest、metrics-append。

### 変更

1. **orchestrator (`scripts/daily-research.sh`)**: 2-pass 一括を **line ごとの
   per-repo ループ**に置換。各 line: `claude -p` を cwd = `target_repo` で起動
   （repo CLAUDE.md 自動ロード）、単一パス（価値選定 + リサーチ + 執筆）。
   - 保持する不変式（ADR-0006 系、調査で確定）:
     - ctl-015: 成功判定は vault のファイル存在（`{date}_{track}_*.md`、flat dir 維持）。
       per-repo 化に伴い**ゲートを line 単位に**（期待数 = line 数、部分成功を
       `report_count` で記録）
     - metrics.jsonl のレコード形は契約（expect-check / metrics-backfill /
       `/dr-review` が消費）。`pass1`/`pass2` 形は **per-line 集約で互換維持**するか
       レコードを明示的に version する（実装時に expect-check `:1099-1138` と
       backfill のログ文字列 regex `:795-867` を確認して決める — ログ行文言は
       de facto API なので改名しない）
     - metrics 収集失敗は非致死 / metrics.jsonl は gitignored のまま
   - lock / log / auth probe / notify / Pass 3 wiki ingest は不変
   - `check_graph_health`（現在 startup-fatal `:97`）は demote（中央 graph を
     読まなくなるため。graph.jsonld 凍結に合わせ health gate 撤去）
   - fallback: Pass 1/2 分離が消えるので、per-line リトライ 1 回のみの単純形に
2. **プロンプト**: `prompts/repo-research-protocol.md`（新規、新メンタルモデル正本）。
   per-line 注入 = config の line 定義 + past-themes（line 別）+ 「repo 自身の
   引用済み文献（.zenodo.json / graph の ExternalReference）を主ソースに再利用禁止」
   （旧 coverage-report の「既出」リスト代替 — 調査指摘の劣化点を塞ぐ）。
   旧 `theme-selection-prompt.md` は削除。`research-protocol.md` の品質規律
   （散文・一次ソース fetch・相互検証・Step 5 保存・past_topics 更新）は新 protocol に継承。
3. **config.toml / config.example.toml**: line 定義維持 + `context_files`
   （repo 内で必ず読む相対パス + private ledger 等の絶対パス — config は gitignored）。
   scoring_criteria → actionability 軸（「この line の次の行動を変えるか」重み最大）。
4. **template (`templates/report-template.md`)**: actionable-tactics 構造へ書き換え。
   frontmatter 互換（wiki ingest / ctl-016 が読む範囲）維持。ctl-016 の
   ARTICLE_SECTIONS 定数（`dr_pipeline.py:876-969`）を新セクション名に同期
   （hard = ソース節 + URL は不変、soft = 新必須節へ更新）。
5. **retire（削除 — eval framework 全削除の repo 前例に従う。git history で復元可能）**:
   - `scripts/coverage-report.sh` / `scripts/bootstrap-graph.sh`
   - `dr_pipeline.py`: `coverage-report` / `cluster-report` / `validate-theme` /
     `parse-stream`（stream-json は Pass 1 専用だった）等、per-repo 形で不要になる
     サブコマンド。`graph-health` は撤去、`past-themes` / `report-lint` /
     `metrics-*` / `expect-check` / `review-age` / `tracks` / `vault-path` 系は保持
   - `lib/graph.sh`（sync_repo_graphs / check_graph_health）と `.repo-graphs` 機構
   - research-protocol Step 6（中央 graph.jsonld 増分）— **graph.jsonld は凍結
     アーカイブ**（削除しない、docs/graph-schema.md は reference-only 注記）
6. **permissions**: per-repo 実行の `--allowedTools` = WebSearch, WebFetch, Read,
   Glob, Grep, Write, Edit — Write/Edit は **vault 配下 + daily-research の
   past_topics.json に限定**する path 指定（repo read-only 不変式を許可レイヤで強制）。
7. **ADR-0008**（daily-research/docs/adr/）: "Per-repo in-context research —
   retire concept-graph-filtered selection"。**supersedes: ADR-0007（全体）+
   ADR-0004 の frontier-mode 選定半分。preserves: ADR-0006（ctl-015/metrics 契約）。
   restates: ADR-0002/0003**（frontier-diff / cross-line circulation の根拠を
   中央 graph から repo native context へ付け替え）。著者診断（一段フィルター /
   裏付け化 / 1 週間陳腐化 worldview）を Context に記録。
8. **テスト更新（調査で特定済み）**:
   - `tests/test-e2e-mock.bats`: 2-pass 前提の全ケース書き換え（mock は per-line
     呼び出し capture 形へ）。auth-stop / ctl-015 両方向 / metrics 記録 / legacy
     config fail-fast は同等ケースを新形で維持
   - `tests/test-daily-research.bats`: coverage/cluster/theme-prompt 注入系
     （`:45-87`）を削除、新 protocol 注入の contract テストに置換
   - `tests/test-lib.bats`: graph 系（`:117-143`）削除、auth/classify_exit/env は不変
   - `tests/dr_pipeline_test.py`: validate-theme 21 ケース + coverage/cluster 系を
     削除、report-lint 新セクション・metrics 互換のテストを追加
9. **docs 同期**: CLAUDE.md / README / RUNBOOK / CONTRIB の該当節。
10. **launchd plist**: entrypoint 不変（`daily-research.sh` のまま）。
11. **毎朝 7:00 の Slack 承認ブリーフ（著者指示、同日 4 通目）**:
    - 新 script `scripts/morning-brief.sh` + 新 launchd plist（毎日 07:00。5:00 の
      リサーチ実行から 2 時間後）
    - 動作: 当日の vault ノート `{date}_*.md` から「今すぐ実行可能な手」節を
      **決定論的に抽出**（新 template がこの節を固定見出しで持つことが前提 —
      template 設計の追加理由）→ line 別・番号付きの実装プラン digest を組み立て
      → **vault `scripts/notify.sh` の `wiki_notify` を source して Slack 送信**
      （webhook 秘匿・macOS フォールバック・「LLM でなく呼び出し元シェルが送る」
      injection-guard 設計をそのまま継承。LLM 要約は挟まない）
    - メッセージ形式: 日付 + line ごとの手（番号 + 一行要約 + ノートファイル名）+
      フッター「承認は次のセッションで『N を実行』と指示（gate は deploy 決定時に適用）」。
      actionable ゼロの日も「本日 actionable なし」を送る（正直な陰性 + 稼働ハートビート）
    - 承認の意味論: Slack webhook は一方向なので、承認自体は著者が次の Claude
      セッション（または Remote Control）で番号を指示して行う。deploy 前 gate
      （判断チェックリスト）はその時点で適用 — 朝の自動送信は提案であって deploy ではない
    - ctl-015/metrics とは独立（brief 失敗は research 成功に影響しない、非致死）

## 外部照合の結果①: research pipeline 設計（2026-08-04 web research、一次ソース fetch 済み）

設計に直接効く確定知見（各主張に日付付き一次ソースあり、詳細は research agent 報告）:

1. **survey-per-run は文書化された anti-pattern**。現行 SOTA は
   **diff-first（snapshot → 構造 diff → 意味 filter → 変化時のみ行動）**
   （Firecrawl /monitor 2026-05-27 / Visualping 2026-05-26、複数 vendor で一致）。
   → 各 line に **watched-source リスト + last-seen 状態**を持たせ、夜間 run は
   「前回からの差分」に主予算、少量の探索 quota を別枠にする。
2. **corroboration 傾向はベンチマーク実証済みの failure mode**
   （PseudoBench arXiv:2606.18060: 誤前提リサーチへの拒否がほぼゼロ、最良でも 27.4%。
   persistent sycophancy arXiv:2607.10526: 同意が memory に書かれ複利化）。
   → run 内に**前提挑戦パス**を必須化: ドラフト後に各 finding を
   「何がこれを反証するか / 我々の ADR と矛盾しないか」で再検査し、ブリーフに
   「我々の立場と矛盾・複雑化する知見」節を必須で持たせる（ADR-0018 falsifiability
   と同型）。
3. **機械的 citation ゲート**: ブリーフ内の全 URL/DOI を run 内で WebFetch 解決
   （arXiv:2604.03173: liveness 自己修正で非解決 URL <1%）。解決不能は落とすか明示マーク。
4. **「本日 actionable なし」を証拠付き一級出力に**（調べた source / 差分あったが
   非実質と判定した項目 1 行ずつ + 理由）。**夜間の手数ノルマは置かない**
   （Goodhart 実証: EvalSafetyGap 2026-06）。
5. **全推奨に失効条件**（valid-until 日付 or 無効化条件）+ 期限切れ項目は次 run で
   再検証してから新規を出す（temporal validity arXiv:2606.26511 / STALE 55.2% /
   Always-On Agents 2026-06-29「state は蓄積でなく統治・放棄が未投資側」）。
6. **自己汚染ガード**: 検索が著者自身の公開 repo を「外部シグナル」として
   拾い戻す混入（search-time contamination 2026-06 の pipeline 版）を明示的に除外。
7. 出力契約は **action-shaped**（Claude Code Routines 2026-04-14 の推奨 recurring
   job は全部「提案されたアクション」形。standalone daily-brief 面は ChatGPT Pulse
   が 2026-06 に廃止 = 行動系に接続しないブリーフは残らない）。
   なお「repo 運用文脈接地の recurring intelligence brief」そのものは
   **公開文献に先行例なし**（本設計が文献より先行する組み合わせ）。

`Verdict: Compose — diff-first monitoring + 前提挑戦パス + citation ゲート + 失効付き brief（各一次ソース確認済みのパターンを単一 CLI run 内に合成。既製の採用可能な OSS pipeline は該当なし）`

## 鮮度・失効の一級制約化（stale-in-a-week worldview の設計反映）

- **ノートの全 claim に日付**: 既に protocol が要求しているが、actionable な手には
  **有効期限の見立て**（例: submission window / spec 改版予定 / 「この手は◯週間で
  陳腐化しうる」）を必須フィールド化する。
- **前回からの差分優先**: 再訪テーマは「何が変わったか」だけを書く（re-survey 禁止）。
- **standing assumption の再検証**: 過去ノートの前提が覆った場合は明示的に
  「反故になった」と書く（wiki 側の stale 照合を助ける）。
- 蓄積層（wiki / graph）の具体的な鮮度設計は web research 結果で確定する。
- **Global rule（実行フェーズで書き込み）**: `~/.claude/rules/common/` に
  「LLM 界隈の知識は 1 週間スケールで陳腐化する — 外部事実は記憶でなく
  検索時点照合（search-first / 一次ソース fetch）を default にする」旨を常駐化。
  既存 `planning.md` rule への追記か新 rule かは rules 慣例（origin / rationale /
  review-when 付き）に従って実装時に決める。

## 外部照合の結果②: 知識オントロジー構築手法（2026-08-04 web research、一次ソース fetch 済み）

1. **現行 Obsidian LLM-wiki は現行 SOTA パターンそのもの** — Karpathy が 2026-04-04
   に gist で公式化（raw 不変層 / wiki LLM 所有層 / schema 層 = 本 vault の既存 3 層と
   一致）。**置き換えない**。markdown + git が single-operator 帯の主流基盤
   （Letta MemFS / AGENTS.md 収斂。反対論の Zep 2026-06-23 は multi-agent
   enterprise 規模の議論で本件に非適用）。
2. **鮮度は LLM に判断させない** — arXiv:2606.01435 (2026-05-31): LLM 裁定の
   temporal-KG (Zep/Graphiti) は FactConsolidation ~7%、決定論的な日付 max 規則は
   78–94.8%。→ claim ごとの as-of 日付 + 「上書きでなく日付付き supersession
   （旧値は残す）」+ stdlib linter で失効検出、が正解。temporal-KG エンジンは導入しない。
3. **永続性の 3 層分離** — arXiv:2604.11364 (2026-04/06): 知識層 =
   persist-until-superseded（減衰なし）/ エピソード層 = 日付付き観測（減衰・archive 可）/
   行動層 = playbook。一律 decay は category error。
4. **行動指向 KB の現行形 = ACE 型 playbook** — arXiv:2510.04618 (ICLR 2026):
   「状況 → 次の行動」単位のページを **delta 更新のみ**で維持（全面再生成は
   context collapse / brevity bias を起こす実測済み failure mode）。
5. **GraphRAG 系 index は建てない** — 2026 コンセンサス: single-operator コーパスに
   graph index は割に合わない。grep + wiki-link + 手書き concept graph で足りる。
   JSON-LD graph は **公開境界の interoperability artifact** としてのみ維持
   （schema-free 内部 + formal ontology は公開境界のみ、AutoSchemaKG 2025-08 系）。

`Verdict: Extend — 既存 LLM-wiki (= SOTA) を維持し、決定論的鮮度規律 + 3 層永続性 + ACE 型 per-line playbook を追加。temporal-KG / GraphRAG / vector DB は導入しない（一次ソース実測が逆を示す）`

## 確定アーキテクチャ: 夜間 run の形（per line、外部照合 ①② を合成)

```
5:00  line ごとに claude -p (cwd = target_repo):
  1. 文脈読込 — repo native (TASKS.md / manifesto OQ / implementation-log /
     config 指定の context_files) + state/<line>/ (watched-sources, last-seen,
     playbook, 失効間近項目)
  2. diff パス — watched sources の前回比差分だけ確認 (re-survey 禁止)。
     失効した standing 項目を先に再検証
  3. 価値選定 — repo の現在地から「今いちばん価値ある前進」を選ぶ。
     探索 quota は別枠で少量 (新 venue / 新機構の発見用)
  4. リサーチ — 一次ソース fetch、全 URL を run 内解決 (citation ゲート)
  5. 前提挑戦パス — 各 finding に反証チェック +「矛盾・複雑化」節必須 +
     自己 repo を外部シグナルとして拾わない (自己汚染ガード)
  6. vault へノート — リード = 今すぐ実行可能な手 (番号付き、各: 手順 / 所要 /
     失効条件)。無い日は証拠付き「本日 actionable なし」。+ 開いた問い + ソース
  7. state 更新 — last-seen / playbook (日付付き delta のみ) / past_topics.json
7:00  morning-brief.sh — 当日ノートから手を決定論抽出 → wiki_notify で
      Slack 承認リクエスト (承認・deploy gate は著者の次セッション)
```

- **state の置き場**: daily-research repo に `state/<line>/`（gitignored、
  運用 private）。vault の構造は変更しない（既に SOTA 3 層に適合済み）。
- playbook = ACE 型「状況 → 次の行動」ページ。morning brief と repo セッションが
  読む。全面書き直し禁止（delta append/amend + 日付 + 失効条件のみ）。

## 実装順序

1. 新プロンプト `repo-research-protocol.md` + template 書き換え（確定アーキテクチャの
   step 1–7 と外部照合①の 7 規律を正本化）
2. orchestrator per-repo ループ化 + state/ 層 + permissions
3. dr_pipeline.py の retire / 保持サブコマンド整理 + ctl-016 セクション同期
4. `morning-brief.sh` + 7:00 plist（wiki_notify 再利用）
5. テスト書き換え → `bats` + `pytest` green
6. ADR-0008 起草（supersedes 0007 / preserves 0006 / restates 0002-0003）+ docs 同期
7. **global rule 書き込み**（`~/.claude/rules/common/` — 「LLM 界隈は 1 週間で陳腐化、
   外部事実は検索時点照合 default」。origin / rationale / review-when 付き）
8. 手動 1 回実行で E2E 確認 → 著者に翌朝の実運用確認を依頼

## Verification

- `bats tests/` + `.venv/bin/python -m pytest` green（更新後テスト）
- 手動 1 回実行（`./scripts/daily-research.sh` を別ターミナルで）→ 4 note が vault に
  生成され、各ノートが「今すぐ実行可能な手」（または証拠付き「本日 actionable なし」）
  リードで始まり、裏付け主題ノートが無いこと・全 URL が解決済みであること
- `morning-brief.sh` 手動実行 → Slack に番号付き承認リクエストが届くこと
  （webhook 未設定なら macOS 通知フォールバック）
- ctl-015 / ctl-016 / metrics.jsonl が機能していること（logs 確認、
  metrics 形の互換 = `expect-check` がエラーなく走ること）
- 翌朝 5:00 / 7:00 の launchd 自動実行を著者が確認
