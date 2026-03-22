# RFC-044: Handle Activity Errors in RFCTaskWorkflow Review and Diff Gates

**Status:** Draft — v1
**Date:** 2026-03-22
**Priority:** High
**Effort:** S

---

## Problem

`temporal/internal/workflows/rfc_impl.go` uses `_ = workflow.ExecuteActivity(...).Get(ctx, &result)` at four sites. The `Future.Get()` return value is the activity's infrastructure error (timeout, panic, cancelled context). Discarding it causes silent misclassification:

**Diff gate (lines 425–437):**

```go
_ = workflow.ExecuteActivity(diffCtx, activities.RunCommand, ...).Get(ctx, &diffResult)
if diffResult.ExitCode == 0 {
    prevReviewFailure = "no changes made — implementer did not modify any tracked..."
    continue
}
```

If the `RunCommand` activity fails with an infrastructure error, `diffResult` is zero-valued and `ExitCode` is `0`. The workflow interprets this as "no changes made" and advances to the next retry attempt. The real cause (e.g., network partition, worker restart) is never logged.

**Review gates (lines 459–470, 486–497):**

```go
_ = workflow.ExecuteActivity(reviewCtx, activities.AgentTask, ...).Get(ctx, &specResult)
if extractSetOutput(specResult.Stdout, "review_passed") != "true" {
    prevReviewFailure = "spec compliance review failed"
    continue
}
```

If the `AgentTask` activity fails, `specResult.Stdout` is empty, `extractSetOutput` returns `""`, and the workflow records a review failure. The actual error (Claude API outage, worker crash) is indistinguishable from a legitimate review rejection in logs.

The cleanup case at `temporal/internal/workflows/rfc_impl.go:307` is intentional best-effort (`// errors are ignored`) and does not need changes.

---

## Solution

Capture and check the error from `Future.Get()` at each of the three problematic sites:

**Diff gate** — treat infra error as "unknown diff state" and proceed (do not skip as "no changes"):

```go
if err := workflow.ExecuteActivity(diffCtx, activities.RunCommand, ...).Get(ctx, &diffResult); err != nil {
    // Infrastructure error: assume changes exist and proceed to review.
    logger.Warn("diff-check activity failed, proceeding to review", "error", err)
} else if diffResult.ExitCode == 0 {
    prevReviewFailure = "no changes made..."
    continue
}
```

`logger` is the `workflow.GetLogger(ctx)` value already obtained at line 287. `rfc_impl.go` does not import `"log/slog"` — use the workflow-native logger.

**Review gates** — treat infra error as a retryable failure with a distinct reason:

```go
if err := workflow.ExecuteActivity(reviewCtx, activities.AgentTask, ...).Get(ctx, &specResult); err != nil {
    prevReviewFailure = fmt.Sprintf("spec review activity error: %v", err)
    // ...continue retry logic...
    continue
}
```

---

## Acceptance Criteria

1. `grep -n '_ = workflow.ExecuteActivity' temporal/internal/workflows/rfc_impl.go` returns at most one line (the intentional cleanup case at the `worktree-remove` call).
2. `cd temporal && go test ./...` passes.
3. The diff-gate and both review-gate `Future.Get()` errors are now checked and logged, confirmed by reading `temporal/internal/workflows/rfc_impl.go` at the three former `_ =` sites.
