# Plan: ノートと wiki を iCloud の vault からローカルの git repo へ移す（notes-off-icloud）

- 起点: 運用者のチャット指示（2026-11-15）。「iCloud のストレージがいっぱいだからだ。もう Obsidian である必要すらない。
  ローカルにレポートを移して、GitHub の専用 repo に push でいい」。wiki ingest は「残す」
- 状態: 承認済み（運用者 2026-11-15「いいよ」。notes repo の名前も同時に承認）
- 調査: 下の「事実」節（内部調査。再現と `file:line` は本 plan に直接書く）

## 事実（2026-11-15 時点）

- 2026-11-12〜15 の 4 日間、呼1 が 25 分無応答で timeout（exit 124）し、retry も同じく落ちた。ノートは 0 本
- 11-15 の `logs/debug/`（166f89d で導入）では、2 回の試行とも呼1 の 2 本目の Write が `tool_dispatch_start` のまま
  `tool_dispatch_end` が無く、一時ファイルの書き込みにも入っていない。1 本目の Write（ローカルの `state/<line>/runs/`）
  は 9ms で終わっている。2 本目は vault（iCloud Drive）へのノートの書き込み（11-14 日中の再現 run の trace で確認）
- 同じ日の 05:50 以降、vault 上の ingest script を bash が 40 分読めずに `Interrupted system call` で落ちた（11-12・11-14）
- `brctl quota` の iCloud 残容量は約 7MB。日中の再現 run（11-14 12:24、2.1.325）は同じ書き込みを即座に通した
- daily-research 本体の vault への依存は `[general].vault_path` だけ（`scripts/lib/dr_pipeline.py` の `vault-path` /
  `report-dir`、`scripts/daily-research.sh` の Pass 3 が `$VAULT_PATH/scripts/daily_wiki_ingest.sh` を呼ぶ箇所）
- vault 側で vault の絶対パスを持つもの: `scripts/daily_wiki_ingest.sh`・`scripts/weekly_wiki_refresh.sh` の `VAULT=`、
  launchd の週次 wiki refresh job、harness の skill `wiki-query`（`VAULT=`）。skill `x-draft` は `config.toml` から解決する
- `wiki/graph.jsonld` は daily-research の `graph.jsonld`（凍結アーカイブ、ADR-0008）への symlink

## 決め

| 項目 | 決め |
|---|---|
| 置き場 | ローカルの新しい git repo（以下 notes repo）。GitHub の private repo を remote にする。名前と path は運用者の `config.toml` の `vault_path` が持ち、公開記録には書かない |
| 配置 | vault と同じ相対配置: `daily-research/`（ノート）・`wiki/`（`concept/`・`index.md`・`log.md`・`.last-auto-ingest`・`graph.jsonld` の symlink）・`scripts/`（ingest・週次 refresh・notify・py）・ingest が読む `CLAUDE.md` / `AGENTS.md`。Obsidian の設定・PDF・`archive/`・添付は移さない |
| 既存のノート | vault から写して notes repo の最初の commit にする。iCloud 側の原本は検証が済むまで残し、削除は運用者が行う |
| daily-research の変更 | `config.toml` の `vault_path` を notes repo に向ける（私的）。`scripts/daily-research.sh` の Pass 3 の後に「notes publish」を足す: `vault_path` が git の作業ツリーのときだけ、その日の変更を commit し、`timeout` 付きで push する。push の失敗は run の成否を変えず、ログと通知に出す（次の run の push がまとめて送る）|
| ingest script | `VAULT=` の絶対パスを script の置き場からの相対に変える。Obsidian 終了などの iCloud 向けの手順はそのまま残す（Obsidian は notes repo を開かないので空振りする） |
| 週次 refresh | launchd job の script パスを notes repo に向ける（運用者の `~/Library/LaunchAgents`、私的） |
| skill | `wiki-query` の `VAULT=` を notes repo の解決に変え、iCloud 固有の注意書きを外す（harness 側で commit） |
| 公開 repo の文書 | README・RUNBOOK・`config.example.toml` の「Obsidian vault」を「ノートの置き場（任意の dir、git なら commit / push する）」に直す |

## 検証

1. notes repo で `git push` が launchd と同じ最小 PATH・環境で通る（keychain の資格情報）ことを、一度きりの launchd job か
   `env -i` の再現で確かめる
2. `DR_FORCE_TRACK=<line>` の試験 run を 1 本（api、上限 $7.75）: ノートが notes repo に書かれ、Pass 3 が notes repo の
   wiki を更新し、commit と push が GitHub に届く
3. `.claude/verify.sh` 緑。notes publish の bats（git 作業ツリーでないとき skip、push 失敗で run の終了コードが変わらない）
4. 翌朝 05:00 の定時 run が timeout せずに完走する（ここが目的の確認）

## やらないこと

- iCloud の容量の整理と、vault の原本の削除（運用者の判断）
- 呼1 の timeout 時の費用見積もり（上限 $4 を計上して残 line を止める挙動）の見直し。別件として報告する
