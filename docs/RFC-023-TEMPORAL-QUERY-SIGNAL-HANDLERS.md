# RFC-023: Add Query and Signal Handlers to Pipeline Workflow

**Status:** Proposed
**Priority:** Medium
**Effort:** M
**Area:** temporal

## Problem

The `Pipeline` and `RFCImpl` workflows expose no query handlers and no signal handlers. This means:

- There is no way to inspect the current state of a running workflow (which steps have completed, which are running, which are queued) without reading the Temporal UI or grepping log files.
- There is no way to send a cancellation signal or a dynamic parameter update to a running workflow from an external caller.
- The `UpsertSearchAttributes` call in `pipeline.go` uses hardcoded attribute names `"CustomStringField"` and `"CustomKeywordField"` (lines ~252-255), which are Temporal's generic examples — they do not describe the pipeline's actual data and will conflict with other workflows using the same names.

## Evidence

`temporal/internal/workflows/pipeline.go` lines ~252-255:
```go
_ = workflow.UpsertSearchAttributes(ctx, map[string]interface{}{
    "CustomStringField":  input.Name,
    "CustomKeywordField": input.Name,
})
```

No `workflow.SetQueryHandler` or `workflow.GetSignalChannel` call anywhere in `pipeline.go` or `rfc_impl.go`.

## Proposed Changes

### Query handler

Register a query handler at workflow start that returns a `PipelineStatus` struct:

```go
type PipelineStatus struct {
    Name        string            `json:"name"`
    Phase       string            `json:"phase"` // "running", "done", "failed"
    StepStates  map[string]string `json:"stepStates"` // stepID -> "pending"|"running"|"done"|"failed"|"skipped"
    CompletedAt *time.Time        `json:"completedAt,omitempty"`
}
```

Register with:
```go
if err := workflow.SetQueryHandler(ctx, "status", func() (PipelineStatus, error) {
    return currentStatus, nil
}); err != nil {
    return err
}
```

### Signal handler

Register a `cancel` signal channel so external callers can gracefully abort a running pipeline:

```go
cancelCh := workflow.GetSignalChannel(ctx, "cancel")
// In the main step loop, select on cancelCh alongside activity futures.
```

### Search attributes

Replace `CustomStringField` / `CustomKeywordField` with properly named attributes:
```go
_ = workflow.UpsertSearchAttributes(ctx, map[string]interface{}{
    "PipelineName": input.Name,
    "PipelineID":   workflow.GetInfo(ctx).WorkflowExecution.ID,
})
```
These attributes must be registered in the Temporal namespace before use.

## Files Changed

- `temporal/internal/workflows/pipeline.go` — add query handler, signal handler, fix search attribute names
- `temporal/internal/workflows/rfc_impl.go` — add status query handler
- `temporal/scripts/` — add a helper script to register the custom search attributes in the namespace

## Verification

```bash
cd temporal && go build ./...
go test ./internal/workflows/...
# Functional: start a pipeline, query its status mid-run:
# tctl workflow query --workflow_id <id> --query_type status
```
