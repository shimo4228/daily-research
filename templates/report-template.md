---
date: {date}
category: {track}  # track name from config.toml
tags: [{tag1}, {tag2}, ...]
topic: "{topic_title}"
sources: {source_count}
---

# {topic_title}

## なぜ今このテーマか
（このトピックが注目に値する理由。2-3文の散文で。）

## 背景
（このトピックの文脈・歴史を散文で記述する。）

## 現在の状況
（最新の動向を散文で記述する。具体的なツール名・数字・事例を盛り込みつつ、
「なぜそれが重要か」「何が変わったのか」を文章で説明する。
箇条書きは比較表や4項目以上の並列列挙に限定し、「見出し→箇条書き→見出し→箇条書き」の連鎖を避ける。）

## 公共圏としての構造
（`public_sphere_radar` variant のみ。人間の役割、AIの役割、公開artifact、参加入口、
持続性、評価・検証、remix・lineage、attribution、アクセス条件を散文または比較表で分析する。
直近の投稿・イベント・更新・参加者など、現在の実活動を示す証拠を最低1件含める。）

## 注目プレイヤー
（主要な企業・プロジェクト・人物を、相互の関係性や業界での位置づけとともに
文章で説明する。単なる名前のリストではなく、なぜ注目すべきかを語る。）

## 未解決の問い
（外部研究がまだ答えていない問いを2-3個、散文で記述する。repo-backed lineでは
各問いが接続するrepo conceptを明示する。自由探索lineではconcept接続を要求しない。
repo の実装状況を推測せず、外部研究・venue側の gap だけを書く。）

## 反証・緊張関係
（maker variant line — config.toml の track に `report_variant = "maker"` がある line —
ではこの節を丸ごと省略する。それ以外の line では、主要な主張と矛盾・緊張する
外部知見を1-2件、散文で記述する。repo-backed lineは対象conceptを明示する。
`public_sphere_radar`はvenueの活動性、アクセス、governance、品質、attributionに関する
反証・リスクを扱う。見つからなければ「反証的知見は見つからなかった」と明記する。）

## ソース
- [タイトル](URL)
- ...

<!-- 末尾節はテーマの種類で分岐する。repo-backed line (テーマ JSON の repos が非空)
     は「この repo への寄与」。自由探索 line (mode: explore) は report_variant により、
     maker =「開発アイデア」、public_sphere_radar =「参加・発信機会」、それ以外 =
     「研究ラインへの接続可能性」。末尾節は必ず1つだけ出力する。 -->

## この repo への寄与
（repo-backed line のみ。散文 3-6 文を基調に、以下の 3 点を必ず含める。
frontier モードのテーマでは「拡張・挑戦」を主、「補強」を従にする。）
- **補強 concept**: （`reinforces` に記録する concept 名と、外部研究がそれをどう裏付けるか）
- **拡張・挑戦**: （concept をどの方向に拡張できるか。「反証・緊張関係」で挙げた知見・`challenges` / `extends` に記録する concept があればここに接続する）
- **取り込み提案**: （新 ADR の種・concept の精緻化・新 concept 候補・graph への追加観点など、人間が repo に取り込むためのフック）

## 開発アイデア
（maker variant の自由探索 line のみ — 他の末尾節の
代わりにこの節を置く。この発見に触発されて読者 (config.toml の user_profile.skills の持ち主)
が自分で作れそうなもの 1-3 案を散文で書く。研究 repo の内部文脈は参照しない —
外部研究の内容と user_profile だけから発想する。各案は数日〜1週間のプロトタイプで
試せる粒度まで具体化する。作る種が見えなければ無理にひねり出さず 1 案でよい。）

## 参加・発信機会
（`public_sphere_radar` variant の自由探索 line のみ — 他の末尾節の代わりにこの節を置く。）
- **Verdict — PILOT | WATCH | DROP**: （3つから1つだけ選び、実活動と参加可能性に基づく理由を書く）
- **最小pilot**: （現在の参加入口から試せる最小の公開実験。外部への投稿・登録はこのレポートでは実行しない）
- **適合する成果**: （AKC・Contemplative Agent・AAPの成果、またはstandaloneなinteractive artifactのどれが適するか。無理なrepo接続はしない）
- **人間のgateと撤退条件**: （人間が保持する著者判断、品質・attribution・利用条件・休眠リスク、続行を止める条件）

## 研究ラインへの接続可能性
（`maker` / `public_sphere_radar` 以外の自由探索 line のみ — 他の末尾節の代わりにこの節を置く。
この発見が既存の研究ラインの concept に将来接続しうるかを 2-3 文の散文で書く。
接続が見えなければ「純粋セレンディピティとして記録する」と明記してよい —
無理な接続をひねり出さない。）
