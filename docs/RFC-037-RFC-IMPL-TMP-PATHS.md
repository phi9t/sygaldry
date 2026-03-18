# RFC-037: Replace Hardcoded /tmp Paths in rfc_impl.go

**Status:** Proposed
**Priority:** Low
**Effort:** XS
**Area:** temporal

## Problem

`temporal/internal/workflows/rfc_impl.go` hardcodes `/tmp/rfc-impl-` and `/tmp/rfc-task-` prefixes for temporary files created during RFC workflow execution. This causes two problems:

1. On hosts where `/tmp` is a small tmpfs (common in CI environments), large RFC plan files can exhaust it.
2. Multiple parallel RFC workflow runs write to paths that differ only by a UUID suffix in `/tmp`, making post-mortem debugging harder and potentially causing race conditions if UUID generation collides.
3. The `review` and `validate` activity errors are silently discarded with `_ = workflow.ExecuteActivity(...)`, meaning a review that fails is invisible to the caller.

## Evidence

`temporal/internal/workflows/rfc_impl.go` line ~106:
```go
taskFile := fmt.Sprintf("/tmp/rfc-impl-%s.json", taskID)
```

Line ~307:
```go
planFile := fmt.Sprintf("/tmp/rfc-task-%s.json", planID)
```

Line ~367:
```go
_ = workflow.ExecuteActivity(ctx, activities.RunCommand, reviewInput)
```

Line ~407:
```go
_ = workflow.ExecuteActivity(ctx, activities.RunCommand, validateInput)
```

## Proposed Changes

1. Use a configurable temp dir from workflow input or a workflow-scoped dir:
   ```go
   tmpDir := input.TempDir
   if tmpDir == "" {
       tmpDir = os.TempDir()
   }
   taskFile := filepath.Join(tmpDir, fmt.Sprintf("rfc-impl-%s.json", taskID))
   ```

2. Add `TempDir string` to `RFCImplInput` and `RFCTaskInput` so callers can set it.

3. Fix the silently discarded review and validate errors. These are informational but should at least be logged:
   ```go
   if err := workflow.ExecuteActivity(ctx, activities.RunCommand, reviewInput).Get(ctx, nil); err != nil {
       logger.Warn("review activity failed (non-fatal)", "error", err)
   }
   ```

4. Consider using `workflow.GetInfo(ctx).WorkflowExecution.RunID` as part of the temp dir path for guaranteed uniqueness.

## Files Changed

- `temporal/internal/workflows/rfc_impl.go` — configurable temp dir, fix silently-discarded errors

## Verification

```bash
cd temporal && go build ./...
go test ./internal/workflows/...
# Verify TempDir field is threaded through correctly.
```
