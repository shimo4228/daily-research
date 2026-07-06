#!/usr/bin/env bash
# coverage-report.sh
# 各 repo graph (.repo-graphs/<key>.jsonld) の concept @id と、
# daily-research graph (graph.jsonld) の関与履歴 (reinforces / challenges / extends)
# を突き合わせ、line → repo 単位で concept coverage と選定モード
# (coverage / frontier) を出力する。
#
# 本体ロジックは scripts/lib/dr_pipeline.py の coverage-report subcommand
# (parser-of-record) に集約されており、本スクリプトは薄い wrapper。
# 出力は Pass 1 (theme-selection) の prompt に concat される。
# stdout に report を出すだけ (副作用なし)。Pass 1 前に daily-research.sh が呼ぶ。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

exec python3 "$PROJECT_DIR/scripts/lib/dr_pipeline.py" coverage-report config.toml graph.jsonld
