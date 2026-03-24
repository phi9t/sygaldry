# RFC-075: Extract Log-Writer Infrastructure from steps.go to logging.go

**Status:** Draft — v1
**Date:** 2026-03-24
**Priority:** Medium
**Effort:** S

---

## Problem

`temporal/internal/activities/steps.go` is 1105 lines. Lines 26-370 contain log-writer
infrastructure (types, methods, constructor) that is logically distinct from the step
activity implementations:

| Lines | Content |
|-------|---------|
| 26–40 | `maxLogBytes` initialization |
| 41–65 | `RunCommandInput` / `RunCommandResult` / `StepEvent` types |
| 66–90 | `structuredLogLine` / `structuredLogSink` types |
| 91–157 | `structuredLogSink.write`, `lineBufferWriter.Write/FlushPartial` |
| 156–181 | `logWriters` type and methods |
| 182–257 | `setupLogWriters` constructor |

This block (230 lines) is independent infrastructure reused by all 8 activity functions
but mixed into the same file as step-specific logic. After RFC-061 removes K8sJob, the
file will still be ~980 lines.

---

## Solution

Move the log-writer block to a new file:

```
temporal/internal/activities/logging.go
```

Contents: everything from line 26 through line 257 of the current `steps.go` (`maxLogBytes`,
all log-writer types and functions). The `setupLogWriters` constructor and all related types
move to `logging.go`; step implementations stay in `steps.go`.

No renames, no API changes. Both files remain in `package activities`.

After the move, `steps.go` starts at `RunCommandInput` (currently line 41) and is
approximately 875 lines, `logging.go` is approximately 230 lines.

---

## Acceptance Criteria

1. `temporal/internal/activities/logging.go` exists.
2. `wc -l temporal/internal/activities/steps.go` outputs ≤ 900 (before RFC-061).
3. `cd temporal && go build ./...` passes.
4. `cd temporal && go test ./...` passes.
