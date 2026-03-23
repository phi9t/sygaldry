# RFC-055: Auto-Close RFC Documents When SAIL Lands a Fix

**Status:** Draft — v1
**Date:** 2026-03-23
**Priority:** Medium
**Effort:** S

---

## Problem

When SAIL successfully implements an RFC and commits the fix, the RFC document in `docs/`
still reads `**Status:** Draft — v1` and the RFC-INDEX.md still lists it under "Open RFCs".
This creates a permanent staleness problem: after every SAIL cycle the index drifts further
from reality. Operators must manually update both files.

---

## Solution

Add a new Python script `tools/agentic/close_rfc.py` and a post-commit step to
`tools/agentic/improvement_loop.yaml` that runs it whenever an RFC issue lands.

### `close_rfc.py` behaviour

```
close_rfc.py --repo-dir <path> --issue-id rfc-054 --commit-sha <sha>
```

1. Derive the RFC filename from the issue id:
   - `rfc-054` → glob `docs/RFC-054-*.md` → take the first match.
   - If no match, exit 0 silently.
2. In the matched RFC file, replace the `**Status:**` line:
   - `**Status:** Draft*` → `**Status:** Done — SAIL (commit <sha>)`
3. In `docs/RFC-INDEX.md`, move the row from Open to Closed:
   - Remove the row from the Open table.
   - Append a row to the Closed table: `| RFC-054 | <title> | Done — SAIL |`
   - Update the header counts.
4. Stage both files with `git add` and amend into the landing commit.
   - If amend fails, fall back to a new commit.

### improvement_loop.yaml addition

Add a step **after** `commit_pr` (conditional on `validate` success, `allow_failure: true`):

```yaml
  - id: close_rfc
    name: Close RFC document on landing
    type: command
    depends_on: [commit_pr]
    when:
      step: validate
      status: success
    allow_failure: true
    command: python3
    args:
      - tools/agentic/close_rfc.py
      - --repo-dir
      - ${{ params.repo_dir }}
      - --issue-id
      - ${{ params.issue_json | jq -r .id }}
      - --commit-sha
      - HEAD
    working_dir: ${{ params.repo_dir }}
    timeout_seconds: 60
```

---

## Acceptance Criteria

1. After SAIL lands an RFC fix, `grep 'Status.*Draft' docs/RFC-<NNN>-*.md` returns empty.
2. The RFC row appears in Closed RFCs in `docs/RFC-INDEX.md`.
3. `./validate_all.sh --quick` passes.
4. Unit tests in `tools/agentic/tests/test_close_rfc.py` cover the status replacement and
   index update logic.
