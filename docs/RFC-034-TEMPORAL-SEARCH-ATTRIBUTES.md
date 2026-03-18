# RFC-034: Replace Hardcoded Temporal Search Attribute Names

**Status:** Proposed
**Priority:** Medium
**Effort:** S
**Area:** temporal

## Problem

`temporal/internal/workflows/pipeline.go` calls `workflow.UpsertSearchAttributes` with the Temporal example attribute names `"CustomStringField"` and `"CustomKeywordField"`. These names:

1. Are not registered in the Temporal namespace, so the upsert silently fails or returns a warning.
2. Do not describe the pipeline's actual data — any dashboard filter using these names matches every workflow in the namespace, not just pipeline workflows.
3. Conflict with any other workflow in the same namespace that also uses `CustomStringField`.

## Evidence

`temporal/internal/workflows/pipeline.go` lines ~252-255:
```go
_ = workflow.UpsertSearchAttributes(ctx, map[string]interface{}{
    "CustomStringField":  input.Name,
    "CustomKeywordField": input.Name,
})
```

The return value is discarded with `_`, so any registration error is silently dropped.

## Proposed Changes

1. Define named constants for the attribute keys:
   ```go
   const (
       searchAttrPipelineName = "PipelineName"
       searchAttrPipelineID   = "PipelineID"
       searchAttrPipelinePhase = "PipelinePhase" // "running" | "done" | "failed"
   )
   ```

2. Register these attributes in the Temporal namespace before the worker starts. Add a `temporal/scripts/register-search-attributes.sh` that runs:
   ```bash
   temporal operator search-attribute create --namespace default \
       --name PipelineName --type Text
   temporal operator search-attribute create --namespace default \
       --name PipelineID --type Keyword
   temporal operator search-attribute create --namespace default \
       --name PipelinePhase --type Keyword
   ```

3. In `pipeline.go`, upsert the properly named attributes and handle the error:
   ```go
   if err := workflow.UpsertSearchAttributes(ctx, map[string]interface{}{
       searchAttrPipelineName:  input.Name,
       searchAttrPipelineID:    workflow.GetInfo(ctx).WorkflowExecution.ID,
       searchAttrPipelinePhase: "running",
   }); err != nil {
       logger.Warn("failed to upsert search attributes", "error", err)
   }
   ```

4. Update `PipelinePhase` to `"done"` or `"failed"` at workflow completion.

## Files Changed

- `temporal/internal/workflows/pipeline.go` — new attribute constants, error handling
- `temporal/scripts/register-search-attributes.sh` — new registration script
- `temporal/scripts/start-temporal.sh` — call the registration script after server start

## Verification

```bash
cd temporal && go build ./...
go test ./internal/workflows/...
# After running: temporal operator search-attribute list --namespace default
# Should list PipelineName, PipelineID, PipelinePhase.
```
