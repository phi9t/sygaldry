# RFC-038: Make MultiEngineAgentTask Heartbeat-Aware

**Status:** Proposed
**Priority:** Medium
**Effort:** S
**Area:** temporal

## Problem

`temporal/internal/activities/multi_engine.go` implements round-robin fallback across multiple agent engines (cursor, gemini, opencode, codex). Between rounds it sleeps using `time.After()`, which:

1. Blocks the goroutine without calling `activity.RecordHeartbeat()`, causing Temporal to time out the activity if the inter-round delay exceeds the heartbeat timeout.
2. Ignores context cancellation during the sleep — if the workflow is cancelled, the activity will sleep the full delay before noticing.
3. Uses `fmt.Printf` for all logging (lines ~95-111), bypassing Temporal's structured activity logger and making logs invisible in the Temporal UI.

## Evidence

`temporal/internal/activities/multi_engine.go` line ~121:
```go
case <-time.After(delay):
    // nothing — no heartbeat
```

Lines ~95-111:
```go
fmt.Printf("[multi_engine] round %d/%d: trying engine %s\n", round, maxRounds, engine)
// ...
fmt.Printf("[multi_engine] all engines failed\n")
```

## Proposed Changes

1. Replace the bare `time.After(delay)` with a heartbeat-aware sleep:
   ```go
   func heartbeatSleep(ctx context.Context, d time.Duration) error {
       ticker := time.NewTicker(10 * time.Second)
       defer ticker.Stop()
       deadline := time.Now().Add(d)
       for time.Now().Before(deadline) {
           select {
           case <-ctx.Done():
               return ctx.Err()
           case <-ticker.C:
               activity.RecordHeartbeat(ctx, "sleeping between engine rounds")
           }
       }
       return nil
   }
   ```

2. Replace all `fmt.Printf` calls with `activity.GetLogger(ctx)`:
   ```go
   logger := activity.GetLogger(ctx)
   logger.Info("trying engine", "round", round, "maxRounds", maxRounds, "engine", engine)
   ```

3. Return a proper error (not just `RunCommandResult{ExitCode: -1}`) when all engines fail, so the Temporal workflow can distinguish "all engines exhausted" from "engine returned non-zero exit code".

## Files Changed

- `temporal/internal/activities/multi_engine.go` — heartbeat-aware sleep, structured logging, typed error

## Verification

```bash
cd temporal && go build ./...
go test ./internal/activities/...
# Integration: run MultiEngineAgentTask with echo engine, verify heartbeats are recorded.
```
