#!/usr/bin/env bats
# Evaluation framework tests
# Run: bats tests/test-eval.bats

PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# === 構文チェック ===

@test "eval-run.sh: bash syntax is valid" {
  bash -n "$PROJECT_DIR/scripts/eval-run.sh"
}

# === ファイル存在チェック ===

@test "judge-system.md exists" {
  [ -f "$PROJECT_DIR/evals/prompts/judge-system.md" ]
}

@test "judge-factual.md exists" {
  [ -f "$PROJECT_DIR/evals/prompts/judge-factual.md" ]
}

@test "judge-depth.md exists" {
  [ -f "$PROJECT_DIR/evals/prompts/judge-depth.md" ]
}

@test "judge-coherence.md exists" {
  [ -f "$PROJECT_DIR/evals/prompts/judge-coherence.md" ]
}

@test "judge-specificity.md exists" {
  [ -f "$PROJECT_DIR/evals/prompts/judge-specificity.md" ]
}

@test "judge-novelty.md exists" {
  [ -f "$PROJECT_DIR/evals/prompts/judge-novelty.md" ]
}

@test "judge-actionability.md exists" {
  [ -f "$PROJECT_DIR/evals/prompts/judge-actionability.md" ]
}

@test "scores.example.jsonl exists" {
  [ -f "$PROJECT_DIR/evals/scores.example.jsonl" ]
}

# === プレースホルダチェック ===

@test "judge-factual.md contains {ARTICLE_CONTENT} placeholder" {
  grep -q '{ARTICLE_CONTENT}' "$PROJECT_DIR/evals/prompts/judge-factual.md"
}

@test "judge-depth.md contains {ARTICLE_CONTENT} placeholder" {
  grep -q '{ARTICLE_CONTENT}' "$PROJECT_DIR/evals/prompts/judge-depth.md"
}

@test "judge-coherence.md contains {ARTICLE_CONTENT} placeholder" {
  grep -q '{ARTICLE_CONTENT}' "$PROJECT_DIR/evals/prompts/judge-coherence.md"
}

@test "judge-specificity.md contains {ARTICLE_CONTENT} placeholder" {
  grep -q '{ARTICLE_CONTENT}' "$PROJECT_DIR/evals/prompts/judge-specificity.md"
}

@test "judge-novelty.md contains {ARTICLE_CONTENT} placeholder" {
  grep -q '{ARTICLE_CONTENT}' "$PROJECT_DIR/evals/prompts/judge-novelty.md"
}

@test "judge-actionability.md contains {ARTICLE_CONTENT} placeholder" {
  grep -q '{ARTICLE_CONTENT}' "$PROJECT_DIR/evals/prompts/judge-actionability.md"
}

# === バイアス緩和指示チェック ===

@test "judge-system.md: anti-verbosity instruction present" {
  grep -q '長さ' "$PROJECT_DIR/evals/prompts/judge-system.md"
}

@test "judge-system.md: anti-self-preference instruction present" {
  grep -q '流暢' "$PROJECT_DIR/evals/prompts/judge-system.md"
}

@test "judge-system.md: JSON output format specified" {
  grep -q '"score"' "$PROJECT_DIR/evals/prompts/judge-system.md"
}

# === scores.example.jsonl スキーマバリデーション ===

@test "scores.example.jsonl: valid JSON" {
  python3 -c "
import json
with open('$PROJECT_DIR/evals/scores.example.jsonl') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        json.loads(line)
"
}

@test "scores.example.jsonl: required fields present" {
  python3 -c "
import json
required = {'date', 'pipeline_version', 'track', 'slug', 'scores', 'total', 'judge_model', 'eval_duration_s'}
score_keys = {'factual_grounding', 'depth_of_analysis', 'coherence', 'specificity', 'novelty', 'actionability'}
with open('$PROJECT_DIR/evals/scores.example.jsonl') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        missing = required - set(d.keys())
        assert not missing, f'Missing fields: {missing}'
        missing_scores = score_keys - set(d['scores'].keys())
        assert not missing_scores, f'Missing score keys: {missing_scores}'
        assert d['total'] == sum(d['scores'].values()), 'total mismatch'
        for k, v in d['scores'].items():
            assert 1 <= v <= 5, f'{k} score out of range: {v}'
"
}

# === daily-research.sh 統合チェック ===

@test "daily-research.sh: eval-run.sh hook is present" {
  grep -q 'eval-run.sh' "$PROJECT_DIR/scripts/daily-research.sh"
}

@test "daily-research.sh: evaluation is non-fatal (uses || pattern)" {
  grep -A2 'eval-run.sh' "$PROJECT_DIR/scripts/daily-research.sh" | grep -q '||'
}
