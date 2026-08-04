# ADR-0008: per-repo in-context research へ全面移行し、concept-graph 駆動のテーマ選定を retire する

## Status

Accepted

## Date

2026-08-04

## Context

ADR-0007 の 4 line = 4 repo コンセプト補強構成は、運用 4 日で運用者から二段階の診断を受けた。

1. **出力の trivia 化**: authorship line（他 line も同傾向）が「外部研究が repo の framework を裏付ける」survey 調のノートを量産していた。目的関数が「概念体系への寄与 (reinforces / challenges / extends)」である限り、リサーチは裏付け (corroboration) に収束し、**実践を前に進める手**を生まない。
2. **構造の根 = 一段フィルター**: pipeline は各 repo を `.repo-graphs/*.jsonld`（概念体系の同期コピー）越しにしか見ない。「進めるべき価値」を知っている運用文脈 — タスク台帳・open questions・実施履歴 — はすべて repo 側にあり、Pass 1 からは不可視。だから選定が graph の gap 埋めに縮退する。

再設計に先立ち外部照合を実施した（2026-08-04、一次ソース fetch 済み）。設計を裏づける主要知見:

- **survey-per-run は文書化された anti-pattern**。現行実務は diff-first（snapshot → 差分 → 意味 filter → 変化時のみ行動）に収斂している（Firecrawl /monitor 2026-05-27、Visualping 2026-05-26）。
- **corroboration 傾向はベンチマーク実証済みの failure mode**。運用者の前提を seed にした research run はそれを裏付けに行く（PseudoBench arXiv:2606.18060: 誤前提リサーチへの拒否は最良でも 27.4%。persistent sycophancy arXiv:2607.10526: 同意が memory に書かれ複利化）。プロンプトの意図だけでは防げず、構造的な対抗策（前提挑戦パス・矛盾節の必須化）が要る。
- **citation の機械ゲートは安価で効く**（arXiv:2604.03173: URL liveness 自己修正で非解決引用 <1%）。
- **推奨には失効条件が要る**（temporal validity arXiv:2606.26511、STALE ベンチマーク: 格納済み前提の silent invalidation 検知は最良 55.2%）。LLM 界隈の知識は 1 週間スケールで陳腐化する、が運用者の standing worldview。
- **手数ノルマは Goodhart 化する**（EvalSafetyGap arXiv:2606.30219）。「本日 actionable なし」を証拠付き一級出力にする方が正しい。
- 蓄積層について: 本 vault の LLM-wiki パターンは 2026-04 に外部で公式化された現行標準に一致しており**置き換え対象ではない**。GraphRAG 型 index・temporal-KG エンジンの導入は single-operator 帯では実測が逆を示す（LLM 裁定の鮮度解決 ~7% vs 決定論的日付規則 78–94.8%、arXiv:2606.01435）。

## Decision

1. **リサーチを各 repo の中から実行する**: orchestrator は line ごとに `claude -p` を **cwd = target_repo** で起動する（単一パス。中央の Opus テーマ選定 Pass 1 は廃止）。入力は repo native な運用文脈 — 自動ロードされる repo 設定 + config の `context_files`（タスク台帳・open questions・実施履歴）。
2. **目的関数を置換する**: 「概念体系の補強」→「**この line を今すぐ前に進める、実行可能な手を見つける**」。レポートは actionable-tactics note（リード = 手 1〜3 件、各: 手順 / 所要 / **失効条件** / gate 留意）。裏付けを主旨とするノートは禁止。actionable な手が無い日は証拠付き「本日 actionable なし」を正の出力とし、手数ノルマは置かない。
3. **run 構造に外部照合の対抗策を組み込む**: diff-first（line ごとの watched-sources + last-seen を `state/<line>/` に永続化し、再 survey を禁止）/ 前提挑戦パス + 「矛盾・複雑化する知見」必須節 / citation ゲート（全 URL を run 内 fetch 解決）/ 自己汚染ガード（運用者自身の成果物を外部シグナルとして数えない）/ playbook は日付付き delta 更新のみ（全面再生成の禁止）。
4. **concept-graph 駆動の選定機構を retire する**: `.repo-graphs` 同期・coverage-report・cluster-report・テーマ JSON 検証・中央 graph.jsonld への日次増分・graph health gate を削除（git history から復元可能）。`graph.jsonld` は凍結アーカイブとして残す。dedup は past_topics.json（aliases 込み）に一本化し、「repo 既引用文献の主ソース再利用禁止」は per-line プロンプトで repo 自身の参照リストを読む形に置換する。
5. **repo は read-only を三層で強制する**: doctrine（プロトコル文言）+ 実行（cwd は repo だが書き込み先は vault / state / past_topics のみ）+ permission 層（`--allowedTools` の Write/Edit を絶対パスで制限）。
6. **毎朝 7:00 の承認ブリーフ**: `morning-brief.sh` が当日ノートの「今すぐ実行可能な手」節を**決定論的に抽出**（LLM を挟まない）し、既存の webhook ヘルパで Slack へ承認リクエストとして送る。承認・deploy 前 gate は運用者のセッション側の行為であり、ノートとブリーフは提案に留まる。
7. **ADR-0006 の自己改善ループは保存する**: ctl-015（vault のレポート存在ゲート、line 単位に精緻化）/ ctl-016 lint（必須節を新テンプレートに同期）/ metrics.jsonl のレコード形（per-line run 群を pass2 に合算して旧形と互換写像、pass1 は None）/ `DR-Expect:` 突合 / `/dr-review`。

本 ADR は **ADR-0007 を supersede** し、**ADR-0004 のうち frontier-mode 選定機構を retire** する（line 再編の系譜としては 0007 の 4 line = 4 repo 対応を継承）。**ADR-0002/0003 の趣旨（フロンティア差分・知識環流）は維持**するが、その実装基盤を中央 concept graph から repo native 文脈 + state 層の diff に付け替える。**ADR-0006 は全面的に preserve** する。

## Alternatives Considered

- **中央 pipeline を維持し、Pass 1/2 プロンプトに repo 運用文脈を注入する（最小変更）** — フィルターは薄まるが、「candidate を graph の語彙で選ぶ」構造と coverage/frontier の目的関数が残り、裏付け収束の根が温存される。メンタルモデルの根を断つには実行位置ごと repo に移す必要があると判断し不採用。
- **authorship line だけ pilot して段階移行** — prototype-before-scale とは整合するが、機構が line 間で二重化し（旧 Pass 1 + 新 per-repo の並走）、orchestrator・テスト・metrics の複雑さが移行期間中ずっと倍になる。全 line が同一機構である方が失敗の観測も単純なため、一括移行 + 初回手動 E2E 検証を選択。
- **coverage / frontier 機構を残して選定の第二軸にする** — 「graph の gap を埋めよ」という指示が残る限り、低摩擦な裏付けテーマへ回帰する誘因が消えない。retire を選択（コードは git history に残る）。
- **朝のブリーフを LLM 要約で生成する** — 夜間ノートは LLM 生成物 = untrusted テキストであり、それを LLM に読ませて通知を書かせる経路は injection 面を増やす。vault の通知ヘルパが既に定める「送信は呼び出し元シェル」の設計に従い、固定見出しの決定論抽出を選択。
- **蓄積層を temporal-KG / GraphRAG 型 index で再構築する** — 外部照合の実測（arXiv:2606.01435 ほか）が single-operator 帯では逆効果を示す。既存 LLM-wiki（現行標準に一致）を維持し、鮮度は決定論的日付規律で扱う。

## Consequences

- リサーチの成果物が「読む資料」から「実行できる提案」に変わり、7:00 の Slack ブリーフ → 運用者の承認 → repo セッションでの gate 済み deploy、という行動ループが閉じる。
- 各 run が repo の private 文脈（タスク台帳等）を読むため、ノートには運用状態への言及が含まれうる。vault は private であり公開面には出ないが、公開転載時は従来どおり運用詳細の抽象化が要る。
- 中央 graph.jsonld の Article 蓄積が止まり、cluster 統計・coverage 集計は将来データが増えない（凍結アーカイブ）。「既出 concept への言及履歴」による dedup は失われ、past_topics + repo 参照リスト + state の watched-sources が代替する。
- 1 晩の claude 実行が 2 回（Opus+Sonnet）から line 数（現行 4 回、リトライ込み最大 8 回）になる。タイムアウトは line あたり 25 分に短縮し、7:00 のブリーフまでに完了する設計だが、コスト・所要は初週の metrics で実測確認する。
- 自由探索 line（repos なし）と `report_variant`（maker / platform_digest）は完全に機能しなくなった（ADR-0007 は「コード残置で復活可能」だったが、本 ADR で担い手の Pass 1 ごと削除）。復活させる場合は per-repo 機構とは別の実行形を設計し直す必要がある。
- metrics.jsonl の `pass1` は今後 None、`fallback_used` はリトライ発生の意味に変わる（フィールド名は互換のため維持）。`expect-check` の pass1 系 metric は新レコードに対して常に INSUFFICIENT_DATA になる。
- 外部照合の知見（diff-first / 前提挑戦 / citation ゲート / 失効条件）はプロンプトとテンプレートに正本化され、ctl-016 が節の存在を機械検査する。ただし節の**中身**の質は従来どおり人間 consumer（/dr-review と朝のブリーフ読者）が判断する — LLM judge は復活させない（ADR-0006）。
