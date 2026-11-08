#!/usr/bin/env python3
"""compare — sandbox-run.sh の出力 dir 複数の指標を表で並べる (stdlib のみ、dev 専用)。

    python3 scripts/dev/compare.py <out_dir>... [--all] [--json] [--labels=a,b,...]

各 dir の eval.json があればそれを、無ければ eval_run.evaluate() で計算する。既定は主要な指標だけを
markdown の表で出す。--all は平らにした全キー、--json は {label: {key: value}} を出す。
最初の列を基準に、数値の行は 2 列目以降に差分 (+n) を添える。
"""

import json
import os
import sys
from collections.abc import Iterable

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import eval_run  # 同じ dir の指標の正本

DEFAULT_KEYS = (
    "run.valid",
    "run.dr_exit",
    "run.duration_s",
    "state.receipt_status",
    "state.reason_code",
    "receipt.valid",
    "note.kind",
    "note.lint_hard",
    "note.lint_soft",
    "note.body_chars",
    "note.unique_urls",
    "note.sources_section",
    "note.date_coverage",
    "note.forbidden_total",
    "note.epistemic_parentheticals",
    "note.first_sentence_internal",
    "note.links_bad",
    "draft.body_chars",
    "draft.date_coverage",
    "draft_vs_final.edit_ratio",
    "evidence.claims",
    "verify.supported",
    "verify.partial",
    "verify.unsupported",
    "verify.unverifiable",
    "verify.edits",
    "verify.supported_rate",
    "call1.cost_usd",
    "call1.turns",
    "call1.duration_s",
    "call1.output_tokens",
    "call1.cache_creation_input_tokens",
    "call1.cache_read_input_tokens",
    "call1.searches",
    "call1.permission_denials",
    "call2.cost_usd",
    "call2.turns",
    "call2.duration_s",
    "call2.output_tokens",
    "novelty.max_jaccard",
)


def flatten(d: object, prefix: str = "") -> dict[str, object]:
    """入れ子の dict を "a.b.c" キーの dict にする。list は JSON 文字列のまま 1 値。"""
    out: dict[str, object] = {}
    if not isinstance(d, dict):
        return out
    for k, v in d.items():
        key = f"{prefix}{k}"
        if isinstance(v, dict):
            out.update(flatten(v, f"{key}."))
        else:
            out[key] = v
    return out


def load(out_dir: str) -> object:
    path = os.path.join(out_dir, "eval.json")
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return eval_run.evaluate(out_dir)


def _num(v: object) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _cell(v: object, base: object = None) -> str:
    if v is None:
        return "—"
    text = json.dumps(v, ensure_ascii=False) if isinstance(v, (list, dict)) else str(v)
    if (
        isinstance(v, (int, float))
        and isinstance(base, (int, float))
        and _num(v)
        and _num(base)
        and v != base
    ):
        delta = v - base
        text += f" ({'+' if delta > 0 else ''}{round(delta, 4)})"
    return text.replace("|", "\\|")


def table(rows: list[dict[str, object]], labels: list[str], keys: Iterable[str]) -> list[str]:
    """rows: [flat dict]、labels: 列名。markdown の表の行のリスト。"""
    lines = ["| metric | " + " | ".join(labels) + " |", "|---|" + "---|" * len(labels)]
    for k in keys:
        vals = [r.get(k) for r in rows]
        if all(v is None for v in vals):
            continue
        base = vals[0]
        cells = [_cell(vals[0])] + [_cell(v, base) for v in vals[1:]]
        lines.append(f"| {k} | " + " | ".join(cells) + " |")
    return lines


def main(argv: list[str]) -> int:
    dirs = [a for a in argv if not a.startswith("--")]
    labels: list[str] | None = None
    for a in argv:
        if a.startswith("--labels="):
            labels = a.split("=", 1)[1].split(",")
    if not dirs:
        print("usage: compare.py <out_dir>... [--all] [--json] [--labels=a,b]", file=sys.stderr)
        return 64
    labels = (
        labels
        if labels and len(labels) == len(dirs)
        else [os.path.basename(os.path.normpath(d)) for d in dirs]
    )
    rows = [flatten(load(d)) for d in dirs]
    if "--json" in argv:
        print(json.dumps(dict(zip(labels, rows, strict=True)), ensure_ascii=False, indent=1))
        return 0
    keys = sorted({k for r in rows for k in r}) if "--all" in argv else list(DEFAULT_KEYS)
    print("\n".join(table(rows, labels, keys)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
