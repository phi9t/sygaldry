# RFC-047: Replace fmt.Printf with slog in multi_engine.go

**Status:** Draft — v1
**Date:** 2026-03-22
**Priority:** Low
**Effort:** XS

---

## Problem

`temporal/internal/activities/multi_engine.go` uses `fmt.Printf` at five sites for progress reporting:

- `multi_engine.go:98` — quota/credits issue (inner loop)
- `multi_engine.go:100` — engine error (inner loop)
- `multi_engine.go:112` — quota/credits issue (outer loop)
- `multi_engine.go:114` — engine failure with exit code
- `multi_engine.go:120` — all engines failed, sleeping before retry

```go
fmt.Printf("[multi_engine] engine %s quota/credits issue (%q)\n", engine, p)
fmt.Printf("[multi_engine] engine %s error: %s\n", engine, stderr)
fmt.Printf("[multi_engine] all engines failed round %d; sleeping %ds before retry\n", round, wait)
```

Every other activity in the `temporal/internal/activities/` package uses `slog` (e.g., `steps.go`, `agent_task.go`). The `fmt.Printf` calls bypass the structured-logging pipeline: their output is not captured in Temporal activity payloads, cannot be filtered by level, and do not carry key-value context. This means multi-engine progress and failures are invisible in the Temporal UI and in `TEMPORAL_LOG_DIR` logs.

---

## Solution

Replace the five `fmt.Printf` calls with `slog.Warn` / `slog.Info` calls:

```go
// line 98 — quota issue (inner)
slog.Warn("multi_engine: quota/credits issue", "engine", engine, "pattern", p)

// line 100 — engine error (inner)
slog.Warn("multi_engine: engine error", "engine", engine, "stderr", stderr)

// line 112 — quota issue (outer)
slog.Warn("multi_engine: quota/credits issue", "engine", engine, "pattern", p)

// line 114 — engine failure
slog.Warn("multi_engine: engine failed", "engine", engine, "exitCode", result.ExitCode, "combined", combined)

// line 120 — sleep before retry
slog.Info("multi_engine: all engines failed this round, sleeping", "round", round, "sleepSeconds", wait)
```

Remove the `"fmt"` import from the file if no other usage remains.

---

## Acceptance Criteria

1. `grep -n 'fmt\.Printf\|fmt\.Println' temporal/internal/activities/multi_engine.go` returns empty.
2. `grep -n 'slog\.' temporal/internal/activities/multi_engine.go | wc -l` returns at least 5.
3. `cd temporal && go test ./...` passes.
