#!/usr/bin/env bash
# daily-research の機械ゲートの単一入口。選定・版・再調査の条件は .claude/verify.md。
#   --staged : commit 境界の速い検査 (staged の .py / .sh だけ。ruff check + format、bash -n、shellcheck)
#   引数なし : 全体 (上 + bats tests/ + pytest の coverage 80%)
# exit: 0 = PASS / 1 = FAIL / 2 = 検査できない (道具が無い。眠っているゲートを stdout に出す)
set -uo pipefail

if [[ -n "${VERIFY_REPO_ROOT:-}" ]]; then
  ROOT="$VERIFY_REPO_ROOT"
else
  ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P) || exit 2
fi
cd "$ROOT" || exit 2

RUFF_VERSION="0.17.3"
MODE="${1:-full}"
fail=0
asleep=()

# uvx が無い・pin した版を取得できない (offline 等) ときは 127 = 眠っているゲート
ruff_ok=""
ruff() {
  if [[ -z "$ruff_ok" ]]; then
    if command -v uvx >/dev/null 2>&1 && uvx --quiet "ruff@${RUFF_VERSION}" --version >/dev/null 2>&1; then
      ruff_ok=1
    else
      ruff_ok=0
    fi
  fi
  ((ruff_ok)) || return 127
  uvx --quiet "ruff@${RUFF_VERSION}" "$@"
}

# 対象ファイル (NUL 区切りで空白入りのパスも 1 要素)
py_files=()
sh_files=()
if [[ "$MODE" == "--staged" ]]; then
  while IFS= read -r -d '' f; do
    case "$f" in
      *.py) py_files+=("$f") ;;
      *.sh) sh_files+=("$f") ;;
    esac
  done < <(git diff --cached --name-only --diff-filter=ACMR -z)
else
  while IFS= read -r -d '' f; do py_files+=("$f"); done < <(git ls-files -z -- '*.py')
  while IFS= read -r -d '' f; do sh_files+=("$f"); done < <(git ls-files -z -- '*.sh')
fi

# --- Python: lint + format ---
if ((${#py_files[@]})); then
  out=$(ruff check --quiet "${py_files[@]}" 2>&1); rc=$?
  if ((rc == 127)); then
    asleep+=("ruff ${RUFF_VERSION} (uvx が無いか取得できない)")
  else
    if ((rc != 0)); then echo "$out"; echo "FAIL ruff check"; fail=1; fi
    out=$(ruff format --check --quiet "${py_files[@]}" 2>&1)
    if (($? != 0)); then echo "$out"; echo "FAIL ruff format (直すには: uvx ruff@${RUFF_VERSION} format <files>)"; fail=1; fi
  fi
fi

# --- Shell: 構文 + shellcheck ---
if ((${#sh_files[@]})); then
  for f in "${sh_files[@]}"; do
    if ! out=$(bash -n "$f" 2>&1); then echo "$out"; echo "FAIL bash -n $f"; fail=1; fi
  done
  if command -v shellcheck >/dev/null 2>&1; then
    # warning 以上を落とす。SC1091 (source 先を追わない) は info なので対象外
    if ! out=$(shellcheck -S warning -x "${sh_files[@]}" 2>&1); then echo "$out"; echo "FAIL shellcheck"; fail=1; fi
  else
    asleep+=("shellcheck (brew install shellcheck)")
  fi
fi

# --- 全体だけ: テスト ---
if [[ "$MODE" != "--staged" ]]; then
  if command -v bats >/dev/null 2>&1; then
    if ! out=$(bats tests/ 2>&1); then echo "$out" | grep -E '^not ok|^#' | head -60; echo "FAIL bats tests/"; fail=1; fi
  else
    asleep+=("bats (brew install bats-core)")
  fi
  if [[ -x .venv/bin/python ]]; then
    if ! out=$(.venv/bin/python -m pytest -q -p no:cacheprovider --cov-fail-under=80 2>&1); then
      echo "$out" | tail -40; echo "FAIL pytest"; fail=1
    fi
  else
    asleep+=("pytest (.venv が無い: uv venv && uv pip install pytest pytest-cov)")
  fi
fi

((fail)) && exit 1
if ((${#asleep[@]})); then
  printf 'ASLEEP %s\n' "${asleep[@]}"
  exit 2
fi
exit 0
