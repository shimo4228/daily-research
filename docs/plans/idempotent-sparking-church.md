# daily-research: human_adaptation 差し替え + human_ai_publics digest 化

## Context

- **human_adaptation**（1 週間前に追加した自由探索 line）のテーマがつまらない。2026-07-24 の tech line が出した Local-first 記事が面白かったが、Local-first 単独 line は固定ドメイン飽和（旧 tech track 廃止の教訓、ADR-0004）を再現するため不採用。代わりに human_adaptation を **「maker のソフトウェアパラダイム転換」の広い傘 line** に差し替える（Local-first / malleable software / self-hosting / personal computing / end-user programming 等を包含）。
- **human_ai_publics** は「行政・公共圏」寄りに漂流し、「AI に親和的な新規プラットフォームを見つけたい」ニーズに応えていない。記事 1 本型をやめ、**その日の探索で見つけた複数プラットフォームを要約付きで列挙する digest 型**（新 report_variant `platform_digest`、3〜7 件/回）に完全移行する（ユーザー確認済み）。public_sphere_radar variant は廃止。

種別: `chore`（config + プロンプト文書の変更、コードロジック変更なし）。dr_pipeline.py のテーマ schema 検証は track 名を config から動的取得するため、コード変更は不要。

## 変更ファイル

### 1. `config.toml`（gitignore 対象・直接編集）

**`[tracks.human_adaptation]` → `[tracks.software_paradigms]` に差し替え**:
- `name = "Software Paradigms 探索"`
- `aliases = ["human_adaptation"]`（past_topics の dedup 履歴を継続）
- `focus`: 個人開発者・maker の視点から見たソフトウェアの作り方・持ち方のパラダイム転換。local-first / sync engine / CRDT、malleable・moldable software、self-hosting・personal infra、end-user programming、personal computing の再興、AI 時代の個人開発手法の変化など。「AI モデル・ツール自体の新着」は tech の担当、agent architecture は agent_systems の担当と明記。飽和 cluster 反発条項は維持
- `report_variant = "maker"` 維持
- `sources`: Hacker News、Lobsters、Local-First 系 (localfirst.fm / FOSDEM devroom 等)、Ink & Switch などの研究ラボ、GitHub Trending、個人開発者ブログ
- `scoring_criteria`: 新規性 / セレンディピティ（飽和 cluster 反発）/ パラダイム性（単発ツールでなく作り方の転換を示すか）/ Buildability / 勢い

**`[tracks.human_ai_publics]` を digest 化**:
- `report_variant = "platform_digest"` に変更
- `focus` 書き直し: AI 親和的（AI-native / AI-friendly）な新規プラットフォーム・venue・community の発見。人間が AI を使って作る・出す・参加することを一級に扱う場。行政・制度・公共圏理論の分析は対象外と明記。除外リスト（agent-only SNS / slop feed 等）は要点のみ維持
- `scoring_criteria`: digest 向けに簡素化（発見の新規性 / AI 親和性 / 実活動 / 参加可能性）
- `config.example.toml` にも同じ構造変更を反映（値は公開テンプレートとして汎用化）

### 2. `prompts/theme-selection-prompt.md`

- 「`public_sphere_radar` variant の選定条件」節を「`platform_digest` variant の選定条件」に置換: この line では単一テーマでなく **その日の探索アングル**（例: 「creative coding 系の AI-native gallery」）を 1 つ選ぶ。テーマ JSON の schema は既存のまま（topic = 探索アングル名、slug 同様）— dr_pipeline の検証を変えないため
- 出力例 JSON の `human_adaptation` エントリを `software_paradigms` に、`human_ai_publics` の rationale 説明を digest 向けに更新

### 3. `prompts/research-protocol.md`

- Step 2 の public_sphere_radar 5 問条項を platform_digest 用に置換: 探索アングルに沿って **複数候補を発見する**ことが目的。深掘り質問でなく横断スイープ（sources を広く回る）
- Step 4 品質基準の public_sphere_radar 条項 2 つ（公共圏構造分析 / 実活動検証）を置換:
  - `platform_digest` variant: 記事構成でなく **digest 構成**（テンプレート参照）。3〜7 件を掲載。**各件に直近の実活動の証拠を最低 1 つ**（確認できない候補は載せない）。past_topics および過去 digest に掲載済みのプラットフォームは再掲禁止（大きな新展開時のみ例外）
  - 反証・緊張節の条項: platform_digest も maker 同様この節を出力しない旨を追記
- 参加・発信機会節の条項を platform_digest 用に書き換え（verdict は件ごとの一言評価に統合）
- Step 5: past_topics.json 更新時、digest line は掲載プラットフォーム名を entry に含める（dedup 用）
- Step 6: digest line の Article ノードは従来通り 1 ノード（topic = 探索アングル）。subCluster 割り当ては維持（cluster 反発の母数）

### 4. `templates/report-template.md`

- 「公共圏としての構造」節・「参加・発信機会」節の public_sphere_radar 記述を撤去
- **`platform_digest` variant 用の別枠テンプレート**を末尾コメント付きで追加:
  - frontmatter は共通（topic = 探索アングル、`items: N` を追加）
  - 構成: `## 今日の探索アングル`（2-3 文）→ 件ごとに `## {プラットフォーム名}` — 何ができる場か（2-4 文）/ AI 親和性（何が AI-native か）/ 実活動の証拠（日付付き）/ 参加入口（URL）/ 一言評価（PILOT | WATCH | DROP + 理由 1 文）→ `## 総評`（3-5 文、横断的な観察）→ `## ソース`
  - 記事型の節構成（背景 / 注目プレイヤー / 未解決の問い / 反証）は digest では使わない旨を明記

## 実行順

1. config.toml → config.example.toml
2. theme-selection-prompt.md → research-protocol.md → report-template.md（参照方向順）
3. CLAUDE.md の line 記述（4 line の列挙 2 箇所）と README があれば追従更新（Doc Sync、同一 diff）

## Verify

- `bats tests/` + `.venv/bin/python -m pytest`（テーマ検証・coverage-report が壊れていないこと。テストが旧 track 名 `human_adaptation` を fixture で参照していれば追従修正）
- `grep -rn "public_sphere_radar\|human_adaptation" scripts/ prompts/ templates/ docs/ tests/` で置換漏れ確認（aliases と ADR の履歴記述は残置で正しい）
- 翌朝の launchd 実行が E2E 検証。手動なら別ターミナルで `./scripts/daily-research.sh`
- コミットはユーザーの diff 確認後
