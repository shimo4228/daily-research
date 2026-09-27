# 新 daily line 「edge」— AI 活用の限界突破事例の毎日観測

## Context

ユーザーの依頼: 「AI 活用をやりすぎて限界突破している事例」を毎日レポートする新 line を追加する。趣旨は「スーパーエッジケースの中こそ学ぶべきことがある」。

- アーキテクチャ (ADR-0008) 上、line は cwd となる接地 repo が必須 → **新規 repo `~/MyAI_Lab/edge-frontier` を新設**(ユーザー確認済み。desire-frontier の先例に倣う最小資料 repo)
- **track 名は `edge`**、`daily = true`(ADR-0011 の daily 機構は残存・現行未使用 — ADR-0012 決定 2 が「速い line が現れたら再利用」と明記しており、supersede ではなく想定通りの再使用)
- 観測範囲(ユーザー確認済み): **突破系**(成功エッジ)+ **崩壊系**(失敗エッジ / post-mortem)+ **生活・認知系エッジ**(開発以外の全面 AI 委譲)の 3 本柱
- daily line 追加は rotating 行数 6 を変えない → **既存 6 line の輪番位相は不変**。毎朝 2 本(輪番 1 + edge)、コスト見込み ~$9/日(ADR-0011 実測 1 line ≒ $4.5)

調査済みの事実(Explore 報告より):
- `_track_rows` の実質必須は `key` + `target_repo` のみ。`target_doi` はコード参照ゼロ(desire と同格で不要)
- `state/edge/` は orchestrator が `mkdir -p` で自動生成、watched-sources / playbook は run 中の LLM が初期化。past_topics も事前登録不要
- **line 追加で壊れるテストはゼロ**(pytest は fixture config のみ、bats は track 名非依存)
- config.example.toml は匿名テンプレなので追記不要
- 制約: track 名は `[a-z_]+`(wiki 逆引き regex)、既存 track と前方一致しないこと → `edge` は適合
- target_repo が存在しないと毎日 E_PARTIAL 通知になる → repo 作成を config 変更より先に行う

## 実装手順

### 1. 接地 repo `~/MyAI_Lab/edge-frontier` の新設(git init + initial commit)

desire-frontier と同型の最小構成。3 ファイル:

- **README.md** — リード(実践者の観測記録であり学術研究ではない、practitioner-identity 準拠)/「3 本柱(初期の見取り図)」表(突破系・崩壊系・生活認知系 / 何を観測するか / 置き場)/「隣接領域との境界(2026-08-20)」節 — 特に **desire-frontier との境界**(desire = 需要が尽きた後の虚無・欲望側 / edge = 活用強度の極端点とそこでの学び。崩壊系の証言が枯渇型なら desire の testimonies へ回す)/「観測ループ」節(daily-research `edge` line、daily cadence、ADR-0013 参照)/「この構造は足場である」節 / Status
- **cases.md** — 事例台帳(desire の testimonies.md 同型): 仮説一文 +「見つからない日も baseline データ」宣言 / Baseline(2026-08-20 時点)節 / 表 `| 発見日 | 発表日 | 主体・場 | 言語 | 型 | URL / メモ |` / 末尾に型分類(仮: 突破・崩壊・生活認知 — 増えたら再編)
- **reading-list.md** — 節骨組み(1. 突破系実践記 / 2. 崩壊系 post-mortem / 3. 生活・認知系 / 4. 方法論・メタ論)+ `[unverified]` 運用ルールと「日付ごと読むこと」注記。初期エントリは空でよい(run が埋める)

GitHub への push はしない(公開はユーザーの別判断)。

### 2. `config.toml` に `[tracks.edge]` を追記(desire の後、`[user_profile]` の前)

```toml
[tracks.edge]
name = "AI Overdrive Edge 観測"
daily = true
focus = "..."   # 3 本柱を明記。骨子: AI 活用を常識外の強度・範囲まで push している一人称事例の捕捉
                # — (1) 突破系: 数十並列エージェント運用・月数千ドル級トークン消費・AI だけで回す事業等の
                # 成功エッジ (2) 崩壊系: やりすぎの果ての failure mode・技能退化・破綻の post-mortem
                # (3) 生活・認知系: 開発以外の意思決定・関係・思考の全面 AI 委譲。
                # 主旨は事例の収集ではなく「エッジから何が学べるか」の抽出。有名事例の再確認 (裏付け) は成果ではない。
                # 見つからない日も baseline として正の出力
context_files = ["README.md", "cases.md", "reading-list.md"]
sources = [ HN / Reddit / X の実践報告スレ, 個人ブログ / Substack の体験記・post-mortem,
            note / Zenn / はてな等の日本語圏 (先行捕捉価値), incident 報道・事後検証記事 ]
scoring_criteria = 既存 3 軸と同型 (影響度 45 / 期限性・鮮度 25 / 反証性・前進性 30)

[[tracks.edge.repos]]
key = "edge"
target_repo = "~/MyAI_Lab/edge-frontier"
```

あわせて config 内コメント(desire 上の「daily 現行使用 line なし」)と `[user_profile].goal` の記述を現状(7 line / daily = edge)へ同期。

### 3. ADR-0013 の起票 — `docs/adr/0013-edge-daily-line.md`

- Status: Accepted。ADR-0012 決定 2 の想定した daily 機構の再使用(supersede なし)
- Context: ユーザー指示(2026-08-20)、事例出現が日単位のイベントである仮説、edge-frontier 新設
- Decision: `edge` line 新設 / daily = true / 接地 repo / 輪番位相不変 / 毎朝 2 本・~$9/日(ADR-0010 の `total_cost_mean <= 13` の内側)
- **Review-when(必須)**: ①収率の源が「外部の日次の動き」でなく在庫消化に転じたら輪番へ戻す(ADR-0012 と同じ失効条件)②4 週後の /dr-review で theme_rank 分布・事例捕捉数を判定 ③ metrics の `pass2` / `fallback_used` が再び 2 line 合算になる — 稼働中 DR-Expect(`fallback_rate` / `pass2_turns_*`)は次回 /dr-review で期間を分けて読む(ADR-0011 決定 4 と同じ扱い)
- `docs/adr/README.md` の index に追記

### 4. Doc sync

- `CLAUDE.md`: 「6 つの研究ライン」→ 7 line(edge は daily)、「2026-08-18 以降は使用 line なし」→ edge が使用(ADR-0013)、Status 節の輪番記述
- `README.md:26`: rotation 6-line + daily edge の記述へ
- `docs/RUNBOOK.md` / `RUNBOOK.ja.md` の daily line 記述(「none configured」箇所)

### 5. Verify(決定論のみ — このセッションから `claude -p` は実行不可)

```bash
python3 scripts/lib/dr_pipeline.py rotation-pick   # 2 行 (輪番 1 + edge\t...\tedge-frontier) を確認
python3 scripts/lib/dr_pipeline.py line-brief edge # focus / criteria / context_files が出ることを確認
bats tests/ && .venv/bin/python -m pytest          # 既存グリーン維持
```

実 E2E は翌朝 5:00 の launchd(または別ターミナルでの手動 `./scripts/daily-research.sh`)。

### 6. Commit(2 repo)

- edge-frontier: initial scaffold commit
- daily-research: config + ADR + doc sync を 1 commit、`DR-Expect:` trailer 付き(例: `edge line のレポートが毎日 1 本存在 / 4 週内に cases.md へ还元 N 件`)。git-workflow skill の作法(git -C、`$( )` 不使用)に従う。push は public repo 確認ルールがあるため commit まで(push はユーザー確認後)
