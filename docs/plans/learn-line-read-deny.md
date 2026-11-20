# plan: 学習の手筋を集める repo line を足し、line ごとの Read deny で読める範囲を狭める

種別: `feat`（config の新しいキー = 無人実行の境界の追加）。Security Review は発火する（権限の境界を動かす）。

## 背景

運用者は、AI を使った学習のノートを足して、自分の学習 repo（非公開）の仕組みを良くしたい。repo に紐づけるのが
得策かは疑問だった（grill-me、2026-11-20）。インタビューで決まったこと:

- **役割**: AI で学ぶ仕組みを自分で回している当事者の手筋を集め、学習 repo に移植できる手を得る
- **研究の扱い**: 無理に追わない。AI 無しの試験で測った効果研究は主題にしない。学習や評価の物差しを AI 前提で
  作り直す議論は、来たら拾う
- **形**: 学習 repo に接地した repo line。学習観と既に入っている仕組みの一覧が repo の 1 文書にあり、ほぼ毎日
  書き足されるので、静的な brief に写すより毎回読むほうがずれない
- **範囲**: 大人の独学の仕組み全般（概念・数学・語学・コード）。学校教育の制度論、EdTech 製品の紹介、
  プロンプト集の how-to は対象外
- **採否**: 「学習 repo に移植できる手を 1 行で言えるか」。無い日は quiet

## 実測（2026-11-20）

| 確かめたこと | 結果 |
|---|---|
| 効果を測る実証研究の物差し（検索 4 本、extended） | 2026 年の新着も AI 無しの試験の点が主流（arXiv 2610.31481、2609.20143）。数か月前に学習理論を回したときと同じ結論の層 |
| 物差しを作り直す議論 | 2026 年に査読誌へ出始めた（pubmed 42935184 の editorial、doi:10.3390/educsci16091507）。概念論文が中心で、新しい物差しで測った実証は見つからなかった |
| 実践者の一次報告 | 一般的な検索語では SEO の how-to 記事に埋もれて拾えなかった。少ないのか検索語の問題かは未確認 — 試行がそのまま答えになる |
| 学習 repo の中身 | 学習観と決まりの文書は数本で、容量の大半は講義本文・教案・対話の記録。対話の記録には、公開の写しで外している私的なやりとりがある |
| line ごとに読める範囲を狭める手段 | 無い。Read deny は全 line 共通（`scripts/daily-research.sh:94-98`）で、line 別に足されるのは Edit deny だけ（同 `:556-576`） |
| 呼2 の読める範囲 | cwd を変えずに `Read` を持つ（同 `:971-978`）。絶対パスで接地 repo を読めるので、line の Read deny は呼2 にも要る |
| 費用 | 2026-11-20 の live run（2 line）の実績に 1 line 分を足しても、1 日の上限（`[billing] daily_cap_usd`）に収まる。実額は私的な支出台帳にある |

## 変更

1. **`[tracks.<x>].read_deny`**（repo 相対の glob の配列、既定は空）を足す。`dr_pipeline._load_tracks` が起動時に
   検証する: 文字列の配列であること、各要素が相対パスで `..` を含まないこと、`--disallowedTools` の区切りを壊す
   文字（`,` `(` `)` と空白・制御文字）を含まないこと。`mode = "ecosystem"` の line では拒否する
   （`_ECOSYSTEM_FORBIDDEN_KEYS`）
2. **deny の描画**: `dr_pipeline.py` に、line の各 `target_repo` × `read_deny` を `Read(//abs/glob)` の列にして出す
   サブコマンドを足す。`daily-research.sh` はその出力を呼1 の `LINE_DISALLOWED` と呼2 の `--disallowedTools` の
   両方に足す。呼3 は Read を持たないので触らない
3. **Glob / Grep が Read deny に従うかを実 CLI で 1 回確かめる**（probe。scratch の dir に deny 対象のファイルを置き、
   `--tools "Read,Glob,Grep"` と `Read(//…/**)` の deny で中身と名前が取れないことを見る）。従わない道具があれば、
   その道具にも同じ glob の deny を描く。結果は script のコメントに as-of 日付で残す
4. **line 定義への反映**: `line-brief` が「読めない場所」を 1 行で出す（モデルが turn を空振りしないため）。
   repo 用プロトコルには line 固有の文言を足さない
5. **テスト**: pytest（`read_deny` の検証の各分岐、ecosystem での拒否、描画の出力）と bats（mock の引数で、
   `read_deny` を持つ line の呼1・呼2 に deny が入り、持たない line には入らないこと）
6. **Doc Sync**: `config.example.toml` の `[tracks.example_line]` に `read_deny` の説明、CLAUDE.md「無人実行の境界」に
   1 行、`daily-research.sh` の該当ブロック直上のコメント。判断の経緯を 1 件（境界の仕組みが増えるため。
   skill `decision-history` の条件で確かめてから書く）
7. **config（私的、commit の外）**: 学習の line を足す。`context_files` は学習観の 1 文書、`read_deny` は講義本文・
   教案・対話の記録、`template` は事件と手筋が主役の既存の line 別テンプレートを試行中は流用する。
   2026-11-21〜12-04 は `daily = true`。具体の値は `.notes/learn-line.md`
8. **当日の確認**: `.claude/verify.sh` を通し、`DR_FORCE_TRACK=<line>` の試験 run を 1 回回して、ノートが届くこと、
   debug log で deny 対象への Read が拒否されるか試みられていないことを見る（API 課金の本番経路なので、
   回す前に運用者の許可を取る）

## やらないこと

- 学習 repo への書き込み（note は読み物。取り込みは運用者が学習 repo の session で行う）
- 学習 repo 側の学習観の文書の追記（「外の研究を毎日集める線は足さなかった」に今回の判断を書き足す）— 別 repo
  なので、この plan の後に学習 repo の側で行う
- この line 専用のテンプレート（輪番に残すと決まってから）
- 事後採点の judge（ADR-0010）

## 判定

- **当日**: 変更 8 が通る
- **2026-12-05**: 14 日のノートから学習 repo の決まり・仕組み・学習観の文書に実際に取り込んだ手を、運用者が数える。
  2 本以上なら `daily` を外して輪番に残す。1 本以下なら line を外し、広域 line の brief に 1 行足す形へ縮める。
  `read_deny` のキーは line を外しても残す（非公開の repo に接地する line の境界として使える）
- **失効条件**: Claude Code が cwd の外を読めない起動形を持つようになったら、`read_deny` を allow 側の列挙に
  置き換えられる。効果研究の物差しが AI 前提のものへ移ったと観測したら、「研究は無理に追わない」を見直す

## 実行者の決定

実装（変更 1〜6）は `Agent(model: "opus")` に委譲する。主ループは plan・config（変更 7）・判断の経緯・検収と
試験 run（変更 8）を持つ。Code Review（effort medium）と `security-reviewer` は実装後に並列で回す。
