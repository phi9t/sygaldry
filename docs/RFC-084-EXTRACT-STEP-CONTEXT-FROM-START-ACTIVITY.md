# RFC-084: Extract stepContext Helper from startActivity in pipeline.go

**Status:** Open
**Date:** 2026-03-25
**Priority:** Low
**Effort:** S

---

## Problem

`temporal/internal/workflows/pipeline.go` `startActivity` (lines 681–870, 189 lines) repeats
the same 5-field assignment block in every case branch:

```go
Name:        stepName(step),
WorkflowID:  info.WorkflowExecution.ID,
RunID:       info.WorkflowExecution.RunID,
StepID:      step.ID,
LogDir:      logDir,
```

This block appears 11 times (once per step type, including the `default` branch).
10 occurrences use two-space alignment (`WorkflowID:  info`) and one occurrence
(the `git_op` branch, line 841) uses four-space alignment (`WorkflowID:    info`)
to align with longer field names in that struct literal. Confirmed:

```
grep -c 'WorkflowID:.*info.WorkflowExecution.ID' temporal/internal/workflows/pipeline.go
```
returns `11`.

---

## Solution

Add a `stepContext` struct at package scope in `pipeline.go` (Go does not allow
type definitions inside functions; define it at the top-level of the `workflows`
package, near `startActivity`):

```go
type stepContext struct {
    name       string
    workflowID string
    runID      string
    stepID     string
    logDir     string
}
```

Add a constructor at the top of `startActivity`:

```go
sc := stepContext{
    name:       stepName(step),
    workflowID: info.WorkflowExecution.ID,
    runID:      info.WorkflowExecution.RunID,
    stepID:     step.ID,
    logDir:     logDir,
}
```

Replace the 5-field block in each case branch with the `sc.*` equivalents.
Use narrow alignment consistently (`Name:       sc.name`, `WorkflowID: sc.workflowID`,
etc.) in all branches — the `git_op` branch currently uses wide alignment to
match the longer field names in `GitOpInput`, so use the same field-aligned
style there too to keep gofmt-clean output.

No new imports, no interface changes, no cross-file changes.

**Note:** After substitution, run `gofmt -w temporal/internal/workflows/pipeline.go`
to normalize any alignment inconsistencies before checking in.

---

## Acceptance Criteria

1. `grep -c 'WorkflowID:.*info.WorkflowExecution.ID' temporal/internal/workflows/pipeline.go` returns `0`
2. `startActivity` is ≤ 150 lines (was 189)
3. `cd temporal && go build ./... && go test ./...` passes
