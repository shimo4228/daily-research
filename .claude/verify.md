# verify の選定記録

入口は `.claude/verify.sh`（`--staged` = commit 境界、引数なし = 全体）。ランタイムは bash + stdlib python3 で、
ここの道具はすべて dev 層（ランタイムには載らない）。

## format
tool: ruff format ==0.17.3（`uvx ruff@0.17.3`）
selected: 2026-10-31
reason: Python の canonical form（diff 安定）。ruff の最新版は 0.17.3（PyPI、2026-10-27）。ruff からの移行は見当たらない
shell: none — shfmt は未導入。bash の整形はゲートにしない（diff の揺れは shellcheck と review で足りている）
re-research triggers: 12 か月経過 / ruff の最終 release が 12 か月より古い / 後継へ移行が起きる

## lint
tool: ruff check ==0.17.3（select は `pyproject.toml`）、shellcheck 0.11.0（brew、`-S warning -x`）
selected: 2026-10-31
reason: ruff はバグクラス（E4/E7/E9/F/B/BLE/RUF）・import 順（I）・古い構文（UP）。shellcheck は shell の
  標準のまま。最終 release は v0.11.0（2025-08-04）で 12 か月の基準を越えるが、代替の shuck（Rust）は作者が
  early-stage と書いている（2026-10-31 時点）ので据え置く
budget: C901 max-complexity = 23 — 分布 n=43、p50=4 / p90=13 / p99=19 / max=23（2026-10-31 測定、最大は
  `cmd_expect_check`）。超えたら上げずに刈る
re-research triggers: 12 か月経過 / shuck が 1.0 に達する / shellcheck の新 release

## type check
tool: none（ratchet 待ち）
selected: 2026-10-31
reason: 境界の型（ANN001-003・ANN201・ANN401、tests 除外）は `dr_pipeline.py` に 75 件の違反がある
  （2026-10-31）。同ファイルを書き換える plan（`docs/plans/happy-growing-bachman.md`）の後に排出して error で入れる。
  型検査器（pyright / ty 等）はその時に search-first で選ぶ
re-research triggers: plan の WP-A 完了 / 12 か月経過

## security
tool: ruff の `S`（bandit 規則）。secret は `scripts/pre-commit.sh`（git hook）と harness の secret scan
selected: 2026-10-31
allowlist: S603 / S607 — git を argv のリストで呼ぶ（shell なし）、PATH は `scripts/lib/env.sh` がサニタイズ。
  tests の S101 / S108 — assert と一時ファイル
re-research triggers: 12 か月経過

## dependency
tool: none
reason: ランタイム依存は stdlib だけ（pip 依存を入れない規約）。dev 依存は pytest / pytest-cov のみ
re-research triggers: ランタイムに依存を足すとき

## test
tool: bats-core（brew。1.13.0 導入済み、最新は v1.14.0 = 2026-07-21）、pytest + pytest-cov（`.venv`、coverage 80% 未満で FAIL）
selected: 2026-10-31
note: 運用者の私的ファイル（config.toml・plist・logs・past_topics.json）を見る bats は、無い checkout では skip
re-research triggers: 12 か月経過

## CI
none — GitHub Actions は未導入（2026-10-31）。bats の一部が macOS 前提（plutil / BSD stat）。cloud session へ
実装を渡す前に `references/ci-verify.yml` の型で入れる
