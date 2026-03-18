# RFC-021: Add Heartbeats to Long-Running Temporal Activities

**Status:** Proposed
**Priority:** High
**Effort:** S
**Area:** temporal

## Problem

`runCommand()` in `temporal/internal/activities/steps.go` is the hot path for every pipeline step including `AgentTask`, `ContainerJob`, and `MultiEngineAgentTask`. It can run for minutes or hours. Temporal requires activities to call `activity.RecordHeartbeat()` periodically when the schedule-to-close timeout exceeds the heartbeat timeout; without heartbeats, a worker restart causes Temporal to mark the activity as timed out and replay it from the beginning.

`MultiEngineAgentTask` in `multi_engine.go` uses `time.After()` for inter-round sleep (line ~121), which blocks the goroutine without any heartbeat, compounding the problem.

## Evidence

`temporal/internal/activities/steps.go` — `runCommand()` function (~line 818–907): no call to `activity.RecordHeartbeat()` anywhere in the function.

`temporal/internal/activities/multi_engine.go` line ~121:
```go
case <-time.After(delay):
    // sleep between engines — no heartbeat
```

A typical agent task runs for 2–20 minutes. The default Temporal heartbeat timeout is 10s–30s depending on workflow configuration. Without heartbeats, any task longer than the heartbeat timeout that survives a worker restart will be re-queued.

## Proposed Changes

1. In `runCommand()`, start a background goroutine that calls `activity.RecordHeartbeat(ctx, progressMsg)` every 10 seconds until the command exits:

```go
heartbeatCtx, cancelHeartbeat := context.WithCancel(ctx)
defer cancelHeartbeat()
go func() {
    ticker := time.NewTicker(10 * time.Second)
    defer ticker.Stop()
    for {
        select {
        case <-heartbeatCtx.Done():
            return
        case <-ticker.C:
            activity.RecordHeartbeat(ctx, "running")
        }
    }
}()
```

2. In `MultiEngineAgentTask`, replace `time.After(delay)` with a heartbeat-aware sleep:

```go
select {
case <-ctx.Done():
    return RunCommandResult{ExitCode: -1}, ctx.Err()
case <-time.After(delay):
    activity.RecordHeartbeat(ctx, fmt.Sprintf("waiting before engine %d", round))
}
```

3. Add `HeartbeatTimeout: 30 * time.Second` to the `ActivityOptions` in `startActivity()` in `pipeline.go` for step types that use `runCommand` as their backend.

## Files Changed

- `temporal/internal/activities/steps.go` — heartbeat goroutine in `runCommand()`
- `temporal/internal/activities/multi_engine.go` — heartbeat-aware inter-round sleep
- `temporal/internal/workflows/pipeline.go` — set `HeartbeatTimeout` in activity options

## Verification

```bash
cd temporal && go build ./...
go test ./internal/activities/...
# Manual: run a 2-minute agent task, restart the worker mid-run, verify
# the task resumes from the heartbeat checkpoint rather than replaying.
```
