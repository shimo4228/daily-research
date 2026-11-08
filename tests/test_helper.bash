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

# 使い捨て repo で git に書き込む test の前に呼ぶ。呼び出し元の GIT_* (git hook と `git rebase --exec` は
# GIT_DIR を export する) を落とす — 残ると git init / config / commit が使い捨て repo でなく実 repo の .git に
# 当たる (2026-11-08 に共有の .git/config へ core.bare = true が書かれた)。運用者の global / system 設定
# (hooksPath・署名) からも切り離す。
isolate_git_env() {
  local v
  while IFS= read -r v; do
    case "$v" in
      GIT_*) unset "$v" ;;
    esac
  done < <(compgen -e)
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
}
