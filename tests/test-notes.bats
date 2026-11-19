#!/usr/bin/env bats
# lib/notes.sh の単体テスト。notes_publish は run の最後で置き場 (vault_path) のその日の分を commit / push する。
# どの失敗も 0 で返る (run の成否を変えない)。stage するのは新しいノートと (許されたときの) wiki/ だけ。

LIB_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib" && pwd)"
load test_helper

setup() {
  TMP="$(mktemp -d)"
  LOG_DIR="$TMP/logs"; LOG_FILE="$LOG_DIR/run.log"
  source "$LIB_DIR/log.sh"; log_init
  notify() { echo "NOTIFY: $2: $1" >> "$LOG_FILE"; }
  source "$LIB_DIR/notes.sh"
  # Slack には出さない: 既定は webhook 無し。送る試験は webhook ファイルを置き、POST を記録で差し替える
  export DR_SLACK_WEBHOOK_FILE="$TMP/no-webhook"
  _notes_slack_post() { cat > "$TMP/slack.json"; echo "$1" > "$TMP/slack.url"; echo 200; }
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
}

teardown() {
  rm -rf "$TMP"
}

# daily-research/ と wiki/ を持つ notes repo と、その origin (bare)
notes_repo() {
  git init -q -b main "$TMP/notes"
  mkdir -p "$TMP/notes/daily-research" "$TMP/notes/wiki"
  echo first > "$TMP/notes/daily-research/a.md"
  echo w > "$TMP/notes/wiki/index.md"
  git -C "$TMP/notes" add -A
  git -C "$TMP/notes" commit -q -m init
  git init -q --bare "$TMP/remote.git"
  git -C "$TMP/notes" remote add origin "$TMP/remote.git"
}

committed_files() { git -C "$TMP/notes" show --name-only --format= HEAD; }
subject() { git -C "$TMP/notes" log -1 --format=%s; }

@test "notes_publish skips a dir that is not a git work tree" {
  mkdir -p "$TMP/plain"
  notes_publish "$TMP/plain" 2026-11-15 daily-research 1
  grep -q "Notes publish: skipped" "$LOG_FILE"
}

@test "notes_publish skips a subdir of another git work tree (only the top counts)" {
  notes_repo
  echo new > "$TMP/notes/daily-research/b.md"
  notes_publish "$TMP/notes/daily-research" 2026-11-15 daily-research 1
  grep -q "Notes publish: skipped" "$LOG_FILE"
  [ "$(git -C "$TMP/notes" rev-list --count HEAD)" -eq 1 ]
}

@test "notes_publish commits the new note and wiki/, and pushes main to origin" {
  notes_repo
  echo new > "$TMP/notes/daily-research/b.md"
  echo w2 > "$TMP/notes/wiki/index.md"
  notes_publish "$TMP/notes" 2026-11-15 daily-research 1
  [ "$(subject)" = "notes: 2026-11-15" ]
  committed_files | grep -qx "daily-research/b.md"
  committed_files | grep -qx "wiki/index.md"
  [ "$(git -C "$TMP/remote.git" rev-parse main)" = "$(git -C "$TMP/notes" rev-parse HEAD)" ]
  grep -q "Notes publish: pushed to origin main" "$LOG_FILE"
}

@test "notes_publish leaves wiki/ out when Pass 3 did not succeed" {
  notes_repo
  echo new > "$TMP/notes/daily-research/b.md"
  echo half-written > "$TMP/notes/wiki/index.md"
  notes_publish "$TMP/notes" 2026-11-15 daily-research 0
  committed_files | grep -qx "daily-research/b.md"
  refute_grep -q "^wiki/" <<< "$(committed_files)"
  [ -n "$(git -C "$TMP/notes" status --short -- wiki)" ]
}

@test "notes_publish stages nothing outside the note dir and wiki/" {
  notes_repo
  echo manual > "$TMP/notes/CLAUDE.md"
  echo new > "$TMP/notes/daily-research/b.md"
  notes_publish "$TMP/notes" 2026-11-15 daily-research 1
  committed_files | grep -qx "daily-research/b.md"
  refute_grep -q "CLAUDE.md" <<< "$(committed_files)"
}

@test "notes_publish leaves a rewritten committed note unstaged and warns" {
  notes_repo
  echo tampered > "$TMP/notes/daily-research/a.md"
  echo new > "$TMP/notes/daily-research/b.md"
  notes_publish "$TMP/notes" 2026-11-15 daily-research 1
  committed_files | grep -qx "daily-research/b.md"
  refute_grep -qx "daily-research/a.md" <<< "$(committed_files)"
  grep -q "committed notes were changed and are left unstaged.*daily-research/a.md" "$LOG_FILE"
  grep -q "NOTIFY: Daily Research Notes" "$LOG_FILE"
}

@test "notes_publish does not commit over changes staged by hand, but still pushes" {
  notes_repo
  echo manual > "$TMP/notes/CLAUDE.md"
  git -C "$TMP/notes" add CLAUDE.md
  echo new > "$TMP/notes/daily-research/b.md"
  notes_publish "$TMP/notes" 2026-11-15 daily-research 1
  [ "$(git -C "$TMP/notes" rev-list --count HEAD)" -eq 1 ]
  grep -q "already has staged changes" "$LOG_FILE"
  [ "$(git -C "$TMP/remote.git" rev-parse main)" = "$(git -C "$TMP/notes" rev-parse HEAD)" ]
}

@test "notes_publish on a branch other than main commits and pushes nothing" {
  notes_repo
  git -C "$TMP/notes" checkout -q -b feature
  echo new > "$TMP/notes/daily-research/b.md"
  notes_publish "$TMP/notes" 2026-11-15 daily-research 1
  [ "$(git -C "$TMP/notes" rev-list --count HEAD)" -eq 1 ]
  grep -q "is on 'feature', not main" "$LOG_FILE"
  [ -z "$(git -C "$TMP/remote.git" for-each-ref refs/heads/feature)" ]
}

@test "notes_publish with nothing new makes no commit but still pushes an earlier unpushed commit" {
  notes_repo
  notes_publish "$TMP/notes" 2026-11-15 daily-research 1
  grep -q "Notes publish: nothing to commit" "$LOG_FILE"
  [ "$(git -C "$TMP/notes" rev-list --count HEAD)" -eq 1 ]
  [ "$(git -C "$TMP/remote.git" rev-parse main)" = "$(git -C "$TMP/notes" rev-parse HEAD)" ]
}

@test "notes_publish keeps the commit when the push fails, and the next run pushes it" {
  notes_repo
  git -C "$TMP/notes" remote set-url origin "$TMP/does-not-exist.git"
  echo new > "$TMP/notes/daily-research/b.md"
  run notes_publish "$TMP/notes" 2026-11-15 daily-research 1
  [ "$status" -eq 0 ]
  [ "$(subject)" = "notes: 2026-11-15" ]
  grep -q "WARN: notes publish — git push failed" "$LOG_FILE"
  grep -q "NOTIFY: Daily Research Notes" "$LOG_FILE"
  git -C "$TMP/notes" remote set-url origin "$TMP/remote.git"
  notes_publish "$TMP/notes" 2026-11-16 daily-research 1
  [ "$(git -C "$TMP/remote.git" rev-parse main)" = "$(git -C "$TMP/notes" rev-parse HEAD)" ]
}

@test "notes_publish returns 0 when the commit fails (a pre-commit hook exits 1)" {
  notes_repo
  printf '#!/bin/sh\nexit 1\n' > "$TMP/notes/.git/hooks/pre-commit"
  chmod +x "$TMP/notes/.git/hooks/pre-commit"
  echo new > "$TMP/notes/daily-research/b.md"
  run notes_publish "$TMP/notes" 2026-11-15 daily-research 1
  [ "$status" -eq 0 ]
  grep -q "git commit failed" "$LOG_FILE"
}

@test "notes_publish without a remote commits and skips the push" {
  notes_repo
  git -C "$TMP/notes" remote remove origin
  echo new > "$TMP/notes/daily-research/b.md"
  notes_publish "$TMP/notes" 2026-11-15 daily-research 1
  [ "$(subject)" = "notes: 2026-11-15" ]
  grep -q "no remote origin — push skipped" "$LOG_FILE"
}

@test "notes_publish does not trip set -Eeuo pipefail or the run's ERR trap on its failure paths" {
  notes_repo
  git -C "$TMP/notes" remote set-url origin "$TMP/does-not-exist.git"
  echo tampered > "$TMP/notes/daily-research/a.md"
  mkdir -p "$TMP/plain"
  run /bin/bash -c "set -Eeuo pipefail
    LOG_DIR='$LOG_DIR'; LOG_FILE='$LOG_FILE'
    source '$LIB_DIR/log.sh'; source '$LIB_DIR/notify.sh'
    notify() { :; }
    trap 'report_unexpected_exit \$? \$LINENO \"\$BASH_COMMAND\"' ERR
    source '$LIB_DIR/notes.sh'
    notes_publish '$TMP/plain' 2026-11-15 daily-research 1
    notes_publish '$TMP/notes' 2026-11-15 daily-research 0
    notes_publish '$TMP/notes' 2026-11-15 '' 1
    echo REACHED_END"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q REACHED_END
  refute_grep -qi "unexpected" "$LOG_FILE"
}

# origin の fetch URL は github.com、push 先は手元の bare (リンクは fetch URL から作る)
github_origin() {
  git -C "$TMP/notes" remote set-url origin https://github.com/owner/notes.git
  git -C "$TMP/notes" remote set-url --push origin "$TMP/remote.git"
  echo https://hooks.example.invalid/x > "$TMP/webhook"
  export DR_SLACK_WEBHOOK_FILE="$TMP/webhook"
}

@test "notes_publish posts GitHub links to this run's new .md notes after the push" {
  notes_repo
  github_origin
  echo new > "$TMP/notes/daily-research/2026-11-15_wide_ノート.md"
  echo x > "$TMP/notes/daily-research/memo.txt"
  notes_publish "$TMP/notes" 2026-11-15 daily-research 1
  grep -q "Notes links: sent to Slack" "$LOG_FILE"
  [ "$(cat "$TMP/slack.url")" = "https://hooks.example.invalid/x" ]
  text=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["text"])' "$TMP/slack.json")
  echo "$text" | grep -qF "*Daily Research 2026-11-15*"
  echo "$text" | grep -qF "<https://github.com/owner/notes/blob/main/daily-research/2026-11-15_wide_%E3%83%8E%E3%83%BC%E3%83%88.md|2026-11-15_wide_ノート>"
  refute_grep -q "memo.txt" <<< "$text"
  refute_grep -q "a.md" <<< "$text"
}

@test "notes_publish posts nothing when the push fails" {
  notes_repo
  github_origin
  git -C "$TMP/notes" remote set-url --push origin "$TMP/does-not-exist.git"
  echo new > "$TMP/notes/daily-research/b.md"
  notes_publish "$TMP/notes" 2026-11-15 daily-research 1
  [ ! -e "$TMP/slack.json" ]
}

@test "notes_publish posts nothing when no note was committed in this run" {
  notes_repo
  github_origin
  notes_publish "$TMP/notes" 2026-11-15 daily-research 1
  [ ! -e "$TMP/slack.json" ]
}

@test "notes_link_digest skips without a webhook file, and for a non-GitHub origin" {
  notes_repo
  notes_link_digest "$TMP/notes" 2026-11-15 daily-research/b.md
  grep -q "Notes links: skipped (no Slack webhook" "$LOG_FILE"
  echo https://hooks.example.invalid/x > "$TMP/webhook"
  DR_SLACK_WEBHOOK_FILE="$TMP/webhook" notes_link_digest "$TMP/notes" 2026-11-15 daily-research/b.md
  grep -q "origin is not a github.com repo" "$LOG_FILE"
  [ ! -e "$TMP/slack.json" ]
}

@test "notes_link_digest returns 0 and warns when the Slack post fails" {
  notes_repo
  github_origin
  _notes_slack_post() { cat > /dev/null; echo 500; }
  run notes_link_digest "$TMP/notes" 2026-11-15 daily-research/b.md
  [ "$status" -eq 0 ]
  grep -q "WARN: notes links — Slack post failed (http=500" "$LOG_FILE"
}
