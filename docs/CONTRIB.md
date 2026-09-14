# Development

The active contract is `scripts/lib/discovery.py`; `scripts/daily-research.sh` owns startup, authentication, locking and wiki handoff. Prompt files own research/editorial judgment. JSON field changes must update the schema, validator, renderer, prompt expectations and tests together.

```bash
bats tests
.venv/bin/python -m pytest
```

Use the repository's existing Python test environment. Tests must mock Claude and use temporary configuration/output paths. A live preview is a separate verification step and must not be reported as passed merely because mocked tests pass.

Cover both stages, normal/briefs/quiet output, missing sources, unresolved versus verified evidence, malformed JSON, authentication failure, timeouts, single retry, concurrent lock, same-date reruns, preview isolation and wiki handoff. Verify command arguments and supplied inputs so project context cannot silently re-enter exploration. Narrative character targets remain editorial guidance.

Do not publish from tests. External text and JSON output are untrusted; validate before filesystem operations. Models receive WebSearch/WebFetch only. No model-selected output paths or shell commands. Changes to reader preferences need human selection; inspection itself does not authorize those changes.

Documentation in both languages describes the current implementation. Historical ADRs preserve previous decisions with dated supersession notes. `graph.jsonld` is archival. Private configuration, logs, packets and baseline copies stay out of commits.
