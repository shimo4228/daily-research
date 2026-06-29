#!/usr/bin/env bash
# graph.sh — graph.jsonld の健全性チェックと repo graph sync。source 専用。
# PROJECT_DIR / DR_PY / LOG_FILE を呼び出し側で定義済みであること。

# graph.jsonld の健全性を missing / parse / schema / ok で区別して判定する。
# 不正なら状況別に notify して 1 を返す (呼び出し側が exit する)。
check_graph_health() {
  local graph="$PROJECT_DIR/graph.jsonld"
  local rc=0
  python3 "$DR_PY" graph-health "$graph" >> "$LOG_FILE" 2>&1 || rc=$?
  case "$rc" in
    0)
      log "graph.jsonld health check passed"
      return 0
      ;;
    2)
      log "ERROR: graph.jsonld not found ($graph)。bootstrap-graph.sh を実行してください"
      notify "graph.jsonld が不在。bootstrap-graph.sh を実行してください" "Daily Research Error"
      ;;
    3)
      log "ERROR: graph.jsonld JSON parse failed"
      notify "graph.jsonld の JSON 構造が壊れています" "Daily Research Error"
      ;;
    4)
      log "ERROR: graph.jsonld schema invalid (@graph 不在)"
      notify "graph.jsonld のスキーマが不正です (@graph 不在)" "Daily Research Error"
      ;;
    *)
      log "ERROR: graph.jsonld health check failed (rc=$rc)"
      notify "graph.jsonld の健全性チェックに失敗" "Daily Research Error"
      ;;
  esac
  return 1
}

# 各 track の target_repo (config.toml) から graph.jsonld を .repo-graphs/ へ sync。
# repo 不在は WARN (該当 track の扱いは Pass 1 に委ねる = 意図的に非 fatal)。
sync_repo_graphs() {
  mkdir -p "$PROJECT_DIR/.repo-graphs"
  local track repo src dst
  while IFS=$'\t' read -r track repo; do
    [ -z "$track" ] && continue
    src="$repo/graph.jsonld"
    dst="$PROJECT_DIR/.repo-graphs/$track.jsonld"
    if [ -f "$src" ]; then
      cp "$src" "$dst"
      log "Synced repo graph: $track <- $src"
    else
      log "WARN: repo graph not found for track '$track': $src"
    fi
  done < <(python3 "$DR_PY" tracks "$PROJECT_DIR/config.toml" 2>> "$LOG_FILE")
}
