# plan: 指定した接地 repo を、run の前に script が早送りで最新にする

種別: `feat`。Security Review は発火する（無人実行が外部と通信し、取り込んだ内容がモデルの文脈に入る）。

## 背景

repo line は接地 repo の手元の写し（`target_repo`）を cwd にして読む。手元で作業している repo は写しが最新だが、
変更が別の場所（クラウドの定期実行など）で起きて origin に push される repo は、手元で誰も pull しないかぎり古くなる。

2026-11-20 に、[ADR-0021](../decision-history/0021-read-deny-for-grounded-repos.md) で足した学習の line の接地 repo が
origin より 50 commit 遅れていた（`git status -sb` が `behind 50`）。同日の試験 run は約 1 日半古い写しを読んでいて、
その間に repo の決まりが 1 回変わっていた。ADR-0021 が repo に接地した理由は「頻繁に書き足される文書を毎回読む」
ことなので、写しが古いと理由が成り立たない。

## 変更

1. `[[tracks.<x>.repos]]` の entry に `sync_before_run`（bool、既定 `false`）を足す。起動時に型を検証する。
2. `dr_pipeline.py` に、1 つの接地 repo を早送りするサブコマンドを足し、`daily-research.sh` が repo line の呼1 の前
   （`repo-activity` より前）に、指定のある repo だけに対して呼ぶ。手順:
   - 作業ツリーが clean で、現在の branch に upstream があるときだけ進む
   - `git fetch`、続けて `git merge --ff-only @{u}`。rebase も merge commit も作らない
   - repo 側の hook を走らせない（`-c core.hooksPath=/dev/null`）。資格情報の入力を待たない
     （`GIT_TERMINAL_PROMPT=0`）。時間の上限を付ける
3. **失敗しても run は止めない。** 汚れた作業ツリー・upstream 無し・早送りできない分岐・通信の失敗・時間切れは、
   pull せずに手元の写しのまま走らせ、理由を log に 1 行で残す（`SYNC <line>: …`）。古い写しを読むのは昨日までと
   同じ状態で、塞ぐ境界（`read_deny`）は写しの新旧に関係なく効く。
4. テスト（pytest: 一時の bare remote で、早送り・clean でない・分岐・upstream 無し・指定なしの各分岐。
   bats: 指定のある line だけで呼ばれ、失敗しても呼1 が走ること）
5. Doc Sync: `config.example.toml`、CLAUDE.md「無人実行の境界」（「repo は read-only」に、script が行う早送りを
   1 行で書く）、CONTRIB・RUNBOOK の各言語版

## やらないこと

- モデルに git を持たせること（境界は変えない。早送りは orchestrator の script が行う）
- 全 repo line への既定の適用（手元で作業中の repo を無人で動かさない。指定した repo だけ）
- 早送りできないときの解決（rebase・stash・reset はしない）

## 判定

- 当日: 指定を付けた repo で、遅れた写しが run の前に origin の先頭へ進み、log に `SYNC` の行が出る
- 失効条件: 接地 repo を手元の写しでなく origin から直接読む実行形ができたら、このキーは要らない

## 残るリスク

早送りで入ってきた新しい置き場は、`read_deny` の列挙に無ければ読める。ADR-0021 の Review-when（列挙の足し忘れ）と
同じ条件で、早送りはその入口を 1 つ増やす。

## 実行者の決定

実装は `Agent(model: "opus")` に委譲する。主ループは plan・config・検収を持ち、Code Review（effort medium）と
`security-reviewer` を実装後に並列で回す。判断は commit 本文（Context / Decision / Review-when）に書く。
