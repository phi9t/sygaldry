# RFC-036: Add Graceful Shutdown to Temporal Worker

**Status:** Proposed
**Priority:** Medium
**Effort:** S
**Area:** temporal

## Problem

`temporal/cmd/worker/main.go` starts the Temporal worker with:
```go
if err := w.Run(worker.InterruptCh()); err != nil {
    log.Fatalf("worker failed: %v", err)
}
```

`worker.InterruptCh()` listens for SIGINT and SIGTERM, but the Temporal Go SDK's default stop behaviour waits indefinitely for all in-flight activities to complete. There is no drain timeout: if an activity hangs (no heartbeat, stuck subprocess), the worker will never shut down cleanly, requiring a `SIGKILL`.

Additionally, the worker uses the standard `log` package. All other Temporal application code should prefer `go.temporal.io/sdk/log` (or `slog`) for structured, context-aware logging that integrates with Temporal's metrics and tracing pipeline.

## Evidence

`temporal/cmd/worker/main.go`:
```go
w.RegisterWorkflow(workflows.Orchestrate)
// ...
if err := w.Run(worker.InterruptCh()); err != nil {
    log.Fatalf("worker failed: %v", err)
}
```

No drain timeout, no structured logger, no graceful-stop timeout configured in `worker.Options{}`.

## Proposed Changes

1. Add a drain timeout to `worker.Options`:
   ```go
   w := worker.New(c, cfg.TaskQueue, worker.Options{
       DeadlockDetectionTimeout: 5 * time.Second,
       WorkerStopTimeout:        30 * time.Second,
   })
   ```

2. Replace `log.Printf` / `log.Fatalf` with `slog` (stdlib since Go 1.21):
   ```go
   import "log/slog"
   slog.Info("worker started", "taskQueue", cfg.TaskQueue, "address", cfg.Address)
   ```

3. Optionally wire `zap` or `go.temporal.io/sdk/log` for full SDK integration.

4. Add a `resolveConfig()` validation step that returns an error if `TEMPORAL_ADDRESS` is empty or malformed, rather than only logging at Fatalf after `client.Dial` fails.

## Files Changed

- `temporal/cmd/worker/main.go` — drain timeout, structured logging, config validation

## Verification

```bash
cd temporal && go build ./cmd/worker
# Start worker, send SIGTERM, verify it exits within WorkerStopTimeout:
timeout 35 go run ./cmd/worker &
PID=$!
sleep 2 && kill -TERM $PID
wait $PID && echo "clean exit"
```
