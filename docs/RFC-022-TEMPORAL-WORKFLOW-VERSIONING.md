# RFC-022: Add Workflow Versioning with workflow.GetVersion

**Status:** Proposed
**Priority:** Medium
**Effort:** S
**Area:** temporal

## Problem

None of the workflow functions (`Pipeline`, `Orchestrate`, `RFCImpl`, `RFCTaskWorkflow`) use `workflow.GetVersion()`. Temporal's determinism requirement means that any change to workflow control flow will cause replay failures for in-flight workflow executions when the worker is updated. Without version guards, a rolling worker deploy that changes branching logic (e.g., adding a new step type, changing retry behaviour, adding a signal handler) will corrupt running workflows.

## Evidence

`temporal/internal/workflows/pipeline.go` — no call to `workflow.GetVersion` in the 938-line file.

`temporal/internal/workflows/rfc_impl.go` — no call to `workflow.GetVersion` in the 551-line file.

This is particularly risky for `RFCImpl` which uses semaphore-based parallelism and will accumulate in-flight runs during active SAIL cycles.

## Proposed Changes

1. Add a version constant at the top of each workflow file:
   ```go
   const workflowVersion = 1
   ```

2. At the start of each workflow function, call `GetVersion` with a change ID:
   ```go
   // Version guard: bump workflowVersion and add a new case here
   // whenever control flow changes.
   v := workflow.GetVersion(ctx, "initial", workflow.DefaultVersion, workflowVersion)
   _ = v
   ```

3. Document the convention in a `WORKFLOW_VERSIONING.md` (or inline comment) so future contributors know to add a new `workflow.GetVersion` call (with a new change ID) whenever they modify branching logic.

4. For `RFCImpl` specifically, add a version guard around the parallelism semaphore pattern, since that is the most likely target for future change.

## Files Changed

- `temporal/internal/workflows/pipeline.go`
- `temporal/internal/workflows/rfc_impl.go`
- `temporal/internal/workflows/orchestrate.go` (if it exists and contains non-trivial logic)

## Verification

```bash
cd temporal && go build ./...
go test ./internal/workflows/...
# Verify no determinism errors in workflow replay tests.
```
