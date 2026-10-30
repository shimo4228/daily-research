# 全 bats ファイル共通の helper。各ファイル冒頭の `load test_helper` で読み込む。

# 否定 assertion。bats は test 本体を set -e で走らせるが、`! cmd` は errexit の対象外で、
# test の最終行でない限り失敗しても検出されない。grep の否定は必ずこの helper で書く
# (変数に対しては `refute_grep -q PATTERN <<< "$var"`、多段パイプは `if ...; then false; fi`)。
# grep 自体のエラー (exit 2 以上 — 対象ファイルが無い等) も fail にする: 「読めなかった」を
# 「一致しなかった」として通さない。
refute_grep() {
  local status=0
  grep "$@" || status=$?
  if [ "$status" -eq 0 ]; then
    echo "refute_grep: unexpected match: grep $*" >&2
    return 1
  elif [ "$status" -ne 1 ]; then
    echo "refute_grep: grep failed (exit $status): grep $*" >&2
    return 1
  fi
}
