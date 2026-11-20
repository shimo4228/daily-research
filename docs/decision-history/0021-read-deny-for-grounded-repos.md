# ADR-0021: 非公開の repo に接地する line のために、接地 repo の読ませない場所を config で列挙し、全 line の run で塞ぐ

## Date

2026-11-20

## Context

Plan: [docs/plans/learn-line-read-deny.md](../plans/learn-line-read-deny.md)（承認 2026-11-20）。

運用者は、AI を使った学習のノートを足して自分の学習 repo（非公開）の仕組みを良くしたいと考え、repo に紐づけるのが
得策かを疑問にしていた。2026-11-20 に agent の session が運用者へ一問ずつ聞くインタビューを行い、line の形を決めた
（決めた中身は Decision 8）。repo に紐づける理由は、学習観と既に入っている仕組みの一覧が学習 repo の 1 文書にあり、
頻繁に書き足されていることだった。静的な brief に写すと実物とずれていく、と見た。

同日の検索 4 本（WebSearch、extended）で次を観測した。

- 効果を測る実証研究は、2026 年の新着も AI 無しの試験の点を物差しにしていた（arXiv 2610.31481、2609.20143）。運用者は、
  以前に学習理論の論文をこの pipeline で回したとき「人間が手を動かして負荷をかけるほうが効く」という結論の論文ばかりが
  出た、と述べた。同じ層だった。
- 物差しを AI 前提で作り直す議論は 2026 年に査読誌へ出始めていた（PubMed 42935184、doi:10.3390/educsci16091507）が、
  概念論文が中心で、新しい物差しで測った実証は見つからなかった。
- **実践者の一次報告は、一般的な検索語では SEO の how-to 記事に埋もれて拾えなかった。** 少ないのか、検索語の問題かは
  確かめていない。これは、選んだ主題（実践者の手筋）に材料が足りない可能性を示す観測である。

学習 repo はそれまでの接地 repo と 2 点で違った。非公開であること、そして容量の大半が講義本文・教案・対話の記録で、
対話の記録に、公開の写しで外している私的なやりとりが含まれることである。呼1・呼2 のモデルは Read を絶対パスで
HOME 全体に持ち、WebFetch で外へ送れる。それまでの Read deny は全 line 共通の固定の一覧
（`scripts/daily-research.sh` の `DISALLOWED_TOOLS`）だけで、接地 repo の中を狭める手段は無かった。

実装後のレビュー 2 本（code review と security review、同日）が、最初の形（その line の呼1・呼2 にだけ deny を足す）に
次の穴を見つけた。

- 他の line の run は、同じ場所を絶対パスで読めた（code review）。
- script が prompt に埋める commit 件名（`repo-activity`）に deny が効いていなかった（code review）。
- `.git/logs/HEAD` と `COMMIT_EDITMSG` から、塞いだ場所に触れた commit の文面が読めた（code review）。
- `./x/**` や `x//y`、`/a/./b` のような書き方が検証を通り、規則が実際のパスに一致しないまま黙って効かない
  可能性があった（両方）。
- config に書く予定だった列挙に、私的な行の逐語の写しを持つ補助ファイル（公開の写しを作るスクリプトの入力）が入って
  いなかった（security review）。列挙は plan を書いた session が決めたもので、config に書く前に見つかった。

Claude Code 2.1.327（haiku）の probe（2026-11-20。結果は `scripts/daily-research.sh` の `read-deny` の配線直上の
コメント）では、scratch の dir に置いた規則 `Read(//<abs>/secret/**)` の下で次を観測した。deny 下のファイルは Glob の
列挙と Grep の検索結果から外れ、path を deny 下に向けた Glob・Grep と Read は拒否された。大文字小文字を変えた path の
Read は拒否された。deny の外に置いた symlink 経由の Read と Glob は拒否され、Grep は一致なしを返した。規則を symlink の
path で書いたときも、実体の path の Read・Grep・Glob は拒否された。

この記録を書いた時点で、実際の接地 repo に対する試験 run（plan の変更 8）はまだ回していない。probe は scratch の dir での
観測である。

## Decision

1. **`[tracks.<x>].read_deny`（repo 相対の glob の配列、既定は空）を足した。** 接地 repo のうちモデルに読ませない
   場所を運用者が列挙する。`mode = "ecosystem"` の line では拒否した（接地 repo が無い）。
2. **deny は全 line の run に効かせた。** `dr_pipeline.py read-deny` が全 line の `target_repo` × glob を
   `Read(//abs/glob)` に描き、`daily-research.sh` が line のループの前に 1 回、全 line 共通の `DISALLOWED_TOOLS` に
   足した。呼1・呼2 は絶対パスで読めるので、その line の run だけを塞いでも他の line の run から読めるためである。
   描けないときは run 全体を止めた。
3. **`read_deny` を持つ repo は `.git/**` も自動で塞いだ。** 運用者が書き忘れても commit の文面が読めないように
   するためである。
4. **`repo-activity` は、塞いだ場所だけに触れた commit を件名の一覧から外した。** `git log` に
   `:(exclude,glob)<glob>` の pathspec を渡した。config を読めないときは件名を 1 つも出さない。
5. **黙って効かなくなる書き方を起動時に拒否した。** glob は相対で、`..`・`.`・空のセグメントと、
   `--disallowedTools` の区切りを壊す文字を含まない。`read_deny` を持つ line の `target_repo` は正規化済みの
   絶対パスで、glob のメタ文字を含まない。
6. **規則は Read だけを描いた。** probe で Glob と Grep が Read の deny に従ったためである。
7. **`line-brief` は、その line の接地 repo の読めない場所を 1 行で出した。** モデルが turn を空振りしないため
   である。
8. **学習の line を運用者の config に足すと決めた。** config は私的なので、line の定義はここに書く。
   - 主題は、AI で学ぶ仕組みを自分で回している当事者の手筋。研究は無理に追わず、AI 無しの試験で測った効果研究は主題に
     しない。物差しを AI 前提で作り直す議論は、来たら拾う。
   - 範囲は大人の独学の仕組み全般（概念・数学・語学・コード）。学校教育の制度論、EdTech 製品の紹介、プロンプト集の
     how-to は対象外。
   - 採否は「学習 repo に移植できる手を 1 行で言えるか」。無い日は quiet。
   - 14 日間（2026-11-21〜12-04）は `daily = true` で回す。ノートから学習 repo に実際に取り込んだ手を運用者が数え、
     2 本以上なら輪番に残し、1 本以下なら line を外して広域 line の brief に 1 行足す形へ縮める。本数の線は運用者が
     インタビューで選んだもので、統計の根拠は無い。結果はその変更の commit 本文に書く。
   - `read_deny` のキーは line を外しても残す。
9. **同じ変更で文書とテストを直した。** `config.example.toml`・`CLAUDE.md`・`README`・`docs/CONTRIB`・`docs/RUNBOOK`
   （後ろ 3 つは各言語版）にキーと境界を書き、`tests/dr_pipeline_test.py` と `tests/test-e2e-mock.bats` に検証・描画・
   全 line への配線・commit 件名の除外のテストを足した。

## Review-when

- Claude Code の版が変わった後の最初の `/dr-review` で、probe（Glob・Grep・大文字小文字・symlink）を回し直して
  すり抜けが出たとき。回帰を自動で見張る仕組みは置いていないので、回し直さない限りこの条件は発火しない。
- 塞ぐ列挙の足し忘れで、私的な内容が読める場所がもう一度見つかったとき（最上位の新しい置き場でも、補助ファイルでも）。
  下の「repo 全体を塞ぎ、読ませる文書を prompt に全文で入れる」へ乗り換える。
- Claude Code が cwd の外を読めない起動形、または deny に例外を書ける規則を持ったとき（列挙の向きを逆にできる）。
- 2026-12-05 の判定で学習の line を外したとき（キーを残す理由が「将来の非公開 repo」だけになる）。

## Alternatives Considered

### 学習の line を足さない

コードも費用も増えない。棄却: 運用者が、状況が変わっているなら足してよいと述べ、検索で一部が動いていると確かめた。
材料が足りない可能性は Decision 8 の 14 日の判定で受ける。

### `read_deny` を作らず、line だけを足す（既存の Read deny とプロトコルの文言に任せる）

コードの変更が要らない。棄却: 呼1・呼2 は Web の内容を読み、WebFetch で外へ送れる。プロンプトの文言は注入に対する
境界にならず、この repo は境界を deny で書く（CLAUDE.md「無人実行の境界」）。私的な対話の記録を持つ repo を、塞がずに
接地先にする理由が無い。

### repo を読まない line にする（ecosystem 形で、関心は静的な brief に書く）

対話の記録をモデルに読ませる経路が最初から無く、コードの変更も要らない。棄却: 移植できる手を言うには既に入っている
仕組みを知る必要があり、その一覧は学習 repo の文書で頻繁に変わる。brief を手で保守する負担が運用者に残り、既知の手の
再発見が届きやすい。

### 既存の line に相乗りする（事例観測の line の対象に学習を足す、または広域 line の brief に 1 行足す）

新しい line も費用も要らない。棄却: 事例観測の line は輪番の 1 枠を他の題材と分け合い、広域 line は 4 領域から毎朝
1 題を選ぶので、学習が選ばれる頻度を保証できない。Open — 再訪条件: 14 日の判定で採用が 1 本以下だったとき
（Decision 8 の縮め方がこの形）。

### その line の呼1・呼2 にだけ deny を足す（最初の実装）

配線が line の中で閉じ、他の line の `--disallowedTools` が長くならない。棄却: 呼1・呼2 は絶対パスで HOME 全体を
読めるので、他の line の run から同じ場所が読める。「私的な記録を読ませない」という目的に届かない。

### repo 全体を塞ぎ、読ませる文書を script が prompt に全文で入れる

足し忘れた場所が読めない側に倒れる。今回の列挙漏れ（補助ファイル）はこの形なら起きなかった。ADR-0020 の呼3 は
この形である（Read を持たせず、ノートと根拠ファイルを prompt に入れる）。採らなかった理由: repo line のプロトコルは
cwd を接地 repo に置き、選定後に repo の CLAUDE.md と `context_files` を Read する作りで、文書を prompt に入れる形は
repo line の実行形をもう 1 つ作ることになる。14 日で残すか決める line のために先に作らなかった。
Open — 再訪条件: 列挙の足し忘れで私的な内容が読める状態がもう一度見つかったとき、または学習の line を輪番に残すと
決めたとき。

### 読める場所を allow の規則で列挙する

同じく足し忘れが読めない側に倒れる。棄却: Claude Code の permission は deny → ask → allow の順に評価され、allow は
deny に例外を作れない（`daily-research.sh` の `AUDIT_TOOLS` の注記）。cwd 相対の否定の glob（`*` を塞いで `!<文書>` で
戻す形）が cwd = 接地 repo で効くかは確かめていない。ADR-0020 は cwd の外のノートについてこの形が使えないと記録したが、
条件が違うのでここには当てはめない。

### 学習 repo の公開の写しに接地する

私的な行が最初から無い。棄却: 写しは講義ノートを公開するためのもので、学習観と決まりの文書が写しに入っているかを
確かめていない。入っていても、写しの側の都合で外れうる。

### Glob と Grep にも同じ glob の deny を描く

CLI の挙動が変わっても塞がる。棄却: probe で Read の規則だけで止まった。効く書式を確かめていない規則を足すと、
効いていると誤解する行が増える。

## Consequences

- 非公開の repo に接地する line を、読ませない場所を選んで作れるようになった。
- 戻すのは軽い。config からキーを消せば規則は描かれず、`read_deny` を持たない repo の出力は変わらない。
- `--disallowedTools` に、`read_deny` を持つ repo ごとに（glob の数 + 1）本の規則が足され、全 line の全呼び出しに入る。
- 境界は列挙なので、接地 repo の構成が変わったときに運用者が一覧を見直す必要がある。足し忘れた場所は読める。
- 何が私的かの記録が 2 か所になった（学習 repo の公開の写しが持つ除外の一覧と、この config の `read_deny`）。
  2 つを揃える仕組みは無い。
- `read_deny` の glob か、それを持つ line の `target_repo` が検証に通らないと起動時に落ち、その朝は全 line が走らない。
- `repo-activity` は、塞いだ場所だけに触れた commit を数えなくなった。対話の記録の commit が大半の repo では、
  直近の活動の一覧が短くなる。塞いだ場所とそれ以外の両方に触れた commit の件名は、引き続き呼1 の prompt に入る。
- deny の対象の名前（ディレクトリ名）は `line-brief` でモデルに見える。中身は見えない。
- 試行の 14 日は、毎朝の呼び出しが 1 line 分増える（額は私的な支出台帳にある）。
- probe は Claude Code の 1 版での観測で、CLI は自動更新される。すり抜けが起きても検知する仕組みは無い。
