# RFC-048: Replace log.Fatal / log.Printf with slog in cmd/orchestrate and cmd/rfc

**Status:** Draft — v1
**Date:** 2026-03-22
**Priority:** Low
**Effort:** XS

---

## Problem

Two `cmd/` packages still use the old `"log"` package instead of `"log/slog"`:

**`temporal/cmd/orchestrate/main.go`:**
- Line 94: `log.Fatal(err)` — fatal startup error (Temporal client creation failure)
- Line 196: `log.Printf("warning: unable to write run manifest: %v", err)` — non-fatal warning

**`temporal/cmd/rfc/main.go`:**
- Line 30: `log.Fatal(err)` — fatal startup error (same pattern)

`cmd/worker/main.go` already uses `slog` exclusively (e.g., `slog.Error`, `slog.Info`). The inconsistency means that error messages from `orchestrate` and `rfc` at startup are formatted differently than worker messages, making log aggregation harder.

---

## Solution

**`temporal/cmd/orchestrate/main.go`:**

Replace line 94:
```go
// before
log.Fatal(err)
// after
slog.Error("fatal", "error", err)
os.Exit(1)
```

Replace line 196:
```go
// before
log.Printf("warning: unable to write run manifest: %v", err)
// after
slog.Warn("unable to write run manifest", "error", err)
```

Remove the `"log"` import if no other usage remains; add `"log/slog"` if not already present.

**`temporal/cmd/rfc/main.go`:**

Replace line 30:
```go
// before
log.Fatal(err)
// after
slog.Error("fatal", "error", err)
os.Exit(1)
```

Remove the `"log"` import; add `"log/slog"` and `"os"` if not already present.

---

## Acceptance Criteria

1. `grep -rn '"log"' temporal/cmd/ --include='*.go'` returns empty (no bare `"log"` import).
2. `grep -rn 'log\.Fatal\|log\.Printf\|log\.Print\b' temporal/cmd/ --include='*.go' | grep -v '_test.go'` returns empty.
3. `cd temporal && go test ./...` passes.
