# RFC-065: Remove steps.json Legacy Pipeline Format Artifact

**Status:** Draft — v1
**Date:** 2026-03-23
**Priority:** Low
**Effort:** XS

---

## Problem

`temporal/examples/steps.json` is a 23-line JSON file containing step definitions in an
old pipeline format that predates the current YAML-based plan schema:

```json
{
  "steps": [
    {"name": "download-data", "command": "curl", "args": [...], ...},
    {"name": "prepare-image", ...},
    {"name": "build-packages", ...}
  ]
}
```

This format is not understood by `cmd/orchestrate`, the validator, or any other Go code.
No Go file, shell script, test, or YAML pipeline references `steps.json`. It is a dead
artifact from an earlier prototype that was superseded when the YAML plan format was
introduced. Retaining it creates confusion about what formats the orchestrator accepts.

---

## Solution

Delete the file:

```
temporal/examples/steps.json
```

No code or documentation changes are required.

---

## Acceptance Criteria

1. `temporal/examples/steps.json` no longer exists.
2. `grep -r "steps\.json" temporal/` returns 0 matches.
3. `cd temporal && go test ./...` passes (no tests reference the file).
