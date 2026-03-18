# RFC-007: Temporal Activity Observability

**Status:** Draft — v1
**Date:** 2026-03-16
**Priority:** Medium

---

## 1. Problem

When a Temporal pipeline fails, diagnosing which step failed and why requires:
1. Looking up the Temporal workflow ID in the UI
2. Finding the activity execution
3. Checking if there's a log file on disk
4. Piecing together context from JSONL logs in `/tmp/logs/`

There is no single, consistent way to correlate a workflow run to its activity outputs. The following gaps make debugging painful:

### 1.1 No structured event emitted on activity completion

`temporal/internal/activities/steps.go` writes structured JSONL events during execution (the `structuredLogSink`), but the final completion event — exit code, duration, success/failure — is only written to `StepEvent` at the end if `StructuredPath != ""`. The Temporal UI shows only the activity return value, not a searchable event log.

### 1.2 No activity heartbeat for long-running steps

Activities running ML training jobs (hours) do not call `activity.RecordHeartbeat()`. Temporal considers an activity timed out after `HeartbeatTimeout` without a heartbeat. Without heartbeats:
- Temporal cannot detect a dead worker holding an activity
- The activity cannot receive cancellation signals
- There is no progress reporting in the Temporal UI

### 1.3 `steps.go` uses `"log"` (stdlib) not slog

All structured context (`workflow_id`, `run_id`, `step_id`) is available in `RunCommandInput` but never attached to log output. Logs from concurrent activities are interleaved and unattributable.

### 1.4 No metrics endpoint

There is no Prometheus `/metrics` endpoint on the worker. CPU, memory, and activity latency are invisible without external tooling.

---

## 2. Changes

### Change 1 — Heartbeat for long-running activities

**File:** `temporal/internal/activities/steps.go`

In `RunCommand()`, start a heartbeat goroutine when `input.TimeoutSecs > 60`:

```go
// In RunCommand(), after starting the subprocess:
if input.TimeoutSecs > 60 {
    heartbeatInterval := 30 * time.Second
    heartbeatCtx, cancelHeartbeat := context.WithCancel(ctx)
    defer cancelHeartbeat()
    go func() {
        ticker := time.NewTicker(heartbeatInterval)
        defer ticker.Stop()
        for {
            select {
            case <-heartbeatCtx.Done():
                return
            case <-ticker.C:
                activity.RecordHeartbeat(ctx, fmt.Sprintf(
                    "step=%s elapsed=%ds", input.StepID, int(time.Since(startTime).Seconds()),
                ))
            }
        }
    }()
}
```

Add `"go.temporal.io/sdk/activity"` to imports. The heartbeat payload is a progress string visible in the Temporal UI.

For the heartbeat timeout, set `HeartbeatTimeout: 2 * heartbeatInterval` in the activity options in `pipeline.go`. This ensures Temporal detects a dead worker within 60 seconds.

### Change 2 — slog in activities (also in RFC-003, but scoped here to steps.go)

**File:** `temporal/internal/activities/steps.go`

At the top of `RunCommand()`:
```go
logger := slog.With(
    "workflow_id", input.WorkflowID,
    "run_id",      input.RunID,
    "step_id",     input.StepID,
    "command",     input.Command,
)
logger.Info("activity started")
// ... on completion:
logger.Info("activity completed",
    "exit_code",  result.ExitCode,
    "duration_s", result.DurationSec,
    "succeeded",  result.ExitCode == 0,
)
```

Replace all `log.Printf` / `log.Println` calls in the file with `logger.Info` / `logger.Error`.

### Change 3 — Heartbeat timeout in pipeline workflow

**File:** `temporal/internal/workflows/pipeline.go`

Update `baseOptions` to include a heartbeat timeout for activities that support it:
```go
// For container_job and agent_task steps (which run for hours):
stepOptions := workflow.ActivityOptions{
    StartToCloseTimeout: stepTimeout,
    HeartbeatTimeout:    90 * time.Second,  // 3 × 30s heartbeat interval
    RetryPolicy:         baseOptions.RetryPolicy,
    ActivityID:          step.ID,
}
```

Apply `HeartbeatTimeout` only to step types that have the heartbeat goroutine:
`container_job`, `agent_task`, `command` (when `timeout_seconds > 60`).

### Change 4 — Prometheus metrics endpoint (optional but recommended)

**File:** `temporal/cmd/worker/main.go`

The Temporal Go SDK includes an optional Prometheus metrics handler. Wire it in:

```go
import "go.temporal.io/sdk/contrib/tally"
import promreporter "github.com/uber-go/tally/v4/prometheus"

// In main(), before client.Dial:
scope, closer := tally.NewRootScope(tally.ScopeOptions{
    Prefix:         "temporal_worker",
    Tags:           map[string]string{"task_queue": cfg.TaskQueue},
    CachedReporter: promreporter.NewReporter(promreporter.Options{}),
    Separator:      promreporter.DefaultSeparator,
}, time.Second)
defer closer.Close()

http.Handle("/metrics", promhttp.Handler())
go http.ListenAndServe(fmt.Sprintf(":%d", cfg.MetricsPort), nil)

c, err := client.Dial(client.Options{
    HostPort:        cfg.Address,
    Namespace:       cfg.Namespace,
    MetricsHandler:  tally.NewMetricsHandler(scope),
})
```

This adds a `/metrics` endpoint with Temporal SDK metrics: workflow start latency, activity schedule-to-start, activity execution time, worker poll counts, etc.

New config field: `metrics_port: 9090` (0 to disable).

**Note:** This adds new dependencies (`go.temporal.io/sdk/contrib/tally`, prometheus reporter). Only implement if metrics are actively consumed by a dashboard.

---

## 3. Files Changed

| File | Action |
|------|--------|
| `temporal/internal/activities/steps.go` | Heartbeat goroutine, slog, progress reporting |
| `temporal/internal/workflows/pipeline.go` | `HeartbeatTimeout` in activity options for long steps |
| `temporal/cmd/worker/main.go` | Optional Prometheus metrics endpoint |
| `temporal/go.mod` | Prometheus/tally deps (Change 4 only) |

---

## 4. Verification

```bash
cd temporal && go test ./...  # all tests pass

# Heartbeat visible in Temporal UI:
# Start a container_job step with timeout > 60s
# Open Temporal UI → workflow → activity → check "heartbeat details"

# slog output:
LOG_FORMAT=json go run ./cmd/worker &
# Trigger an activity → check stdout for workflow_id/run_id/step_id fields
```

---

## 5. Risk Register

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Heartbeat goroutine leaks on panic | Low | `defer cancelHeartbeat()` in activity function |
| HeartbeatTimeout too short for slow ML jobs | Medium | Set generous default (90s); configurable per step |
| Prometheus deps add binary size | Low | Change 4 is optional; only add if consumed |
| slog import conflicts with RFC-003 | None | Both RFCs write to same file; apply together |
