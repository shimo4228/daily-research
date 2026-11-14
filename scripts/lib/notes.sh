#!/usr/bin/env bash
# notes.sh — ノートの置き場 (vault_path) が git の作業ツリーなら、run の最後にその日の分を commit して push する。
# source 専用。log() / notify() / LOG_FILE を呼び出し側で定義済みであること。
#
# 置き場は iCloud の vault から移した (plan docs/plans/notes-off-icloud.md: iCloud の容量切れで、早朝のノートの
# Write が返らず呼1 が 25 分 timeout した)。どの段の失敗も run の成否を変えない (常に 0 を返す)。

# notes_publish <dir> <date> <notes_rel> <include_wiki>
#   dir         置き場 (git の作業ツリーの root でなければ何もしない)
#   notes_rel   dir から見たノートの dir (例 daily-research)。空ならノートは stage しない
#   include_wiki  "1" のときだけ wiki/ の変更を stage する (Pass 3 が失敗した日の途中の wiki を送らない)
# stage するのは run が書くものだけ: notes_rel の新しいファイルと、include_wiki のときの wiki/。
#   - commit 済みのノートが書き換わっていたら stage せずに警告する (ノートの層は read-only。ingest の
#     プロンプトインジェクションや手作業の編集を、run の commit に紛れ込ませない)
#   - 実行前から index に stage 済みの変更があれば commit しない (手作業の途中を巻き込まない)
#   - main 以外の branch にいるときは commit も push もしない
# push は origin の main へ timeout 付き。GIT_TERMINAL_PROMPT=0 は資格情報の入力待ちで止まらないため
notes_publish() {
  local dir=$1 date=$2 notes_rel=$3 include_wiki=$4 top branch modified f
  local -a new_notes=()
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || top=""
  if [ -z "$top" ] || [ "$(cd "$top" && pwd -P)" != "$(cd "$dir" && pwd -P)" ]; then
    log "Notes publish: skipped ($dir is not the top of a git work tree)"
    return 0
  fi
  branch=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null) || branch=""
  if [ "$branch" != "main" ]; then
    log "WARN: notes publish — $dir is on '${branch:-detached HEAD}', not main; nothing committed or pushed"
    notify "ノート repo が main 以外にあるため commit / push しませんでした" "Daily Research Notes"
    return 0
  fi
  if ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
    log "WARN: notes publish — $dir already has staged changes; nothing committed (finish or unstage them by hand)"
    notify "ノート repo に stage 済みの変更があるため commit しませんでした" "Daily Research Notes"
  else
    if [ -n "$notes_rel" ]; then
      modified=$(git -C "$dir" diff --name-only -- "$notes_rel" 2>/dev/null) || modified=""
      if [ -n "$modified" ]; then
        log "WARN: notes publish — committed notes were changed and are left unstaged (the note layer is read-only): $(printf '%s' "$modified" | head -5 | tr '\n' ' ')"
        notify "commit 済みのノートが書き換えられています。stage せずに残したので確認してください" "Daily Research Notes"
      fi
      while IFS= read -r -d '' f; do
        new_notes+=("$f")
      done < <(git -C "$dir" ls-files -z --others --exclude-standard -- "$notes_rel" 2>/dev/null)
      if [ "${#new_notes[@]}" -gt 0 ] && ! git -C "$dir" add -- "${new_notes[@]}" >> "$LOG_FILE" 2>&1; then
        log "WARN: notes publish — git add of the new notes failed (non-fatal)"
      fi
    fi
    if [ "$include_wiki" = "1" ] && [ -d "$dir/wiki" ] && ! git -C "$dir" add -A -- wiki >> "$LOG_FILE" 2>&1; then
      log "WARN: notes publish — git add of wiki/ failed (non-fatal)"
    fi
    if git -C "$dir" diff --cached --quiet 2>/dev/null; then
      log "Notes publish: nothing to commit (wiki included: ${include_wiki:-0})"
    elif git -C "$dir" commit -q -m "notes: $date" >> "$LOG_FILE" 2>&1; then
      log "Notes publish: committed $(git -C "$dir" rev-parse --short HEAD) (notes: $date, ${#new_notes[@]} new note(s), wiki included: ${include_wiki:-0})"
    else
      log "WARN: notes publish — git commit failed in $dir (non-fatal; changes stay staged)"
      notify "ノート repo の commit に失敗しました" "Daily Research Notes"
    fi
  fi
  if ! git -C "$dir" remote get-url origin > /dev/null 2>&1; then
    log "Notes publish: no remote origin — push skipped"
    return 0
  fi
  if GIT_TERMINAL_PROMPT=0 timeout -k 10 120 git -C "$dir" push -q origin main >> "$LOG_FILE" 2>&1; then
    log "Notes publish: pushed to origin main"
  else
    log "WARN: notes publish — git push failed (non-fatal; commits stay local and the next run retries. A rejected push (origin main moved) needs a manual pull)"
    notify "ノート repo の push に失敗しました。次の run が再送します (毎日続くなら手で pull が要ります)" "Daily Research Notes"
  fi
  return 0
}
