# RFC-045: Parse TEMPORAL_LOG_MAX_BYTES Once at Worker Startup

**Status:** Draft — v1
**Date:** 2026-03-22
**Priority:** Low
**Effort:** S

---

## Problem

`temporal/internal/activities/steps.go:968–971` re-reads and re-parses `TEMPORAL_LOG_MAX_BYTES` on every call to `runCommand`:

```go
maxBytes := int64(10_000)
if value := os.Getenv("TEMPORAL_LOG_MAX_BYTES"); value != "" {
    if parsed, parseErr := strconv.ParseInt(value, 10, 64); parseErr == nil && parsed > 0 {
        maxBytes = parsed
    }
}
```

This means:
- Every activity invocation performs a syscall (`os.Getenv`) and a string parse.
- A misconfigured value (e.g. `"10k"` instead of `"10000"`) is silently ignored on every call with no log output.
- The env var is not validated at startup — a bad value is only discovered when reviewing truncated output.

The analogous constant `10_000` also appears only as a magic literal with no named constant and no mention in the worker's effective-config printout.

---

## Solution

1. Add a package-level `maxLogBytes` variable (or a `sync.Once`-initialized value) in `temporal/internal/activities/steps.go` that reads `TEMPORAL_LOG_MAX_BYTES` once:

```go
var maxLogBytes = func() int64 {
    const defaultMaxBytes = 10_000
    v := os.Getenv("TEMPORAL_LOG_MAX_BYTES")
    if v == "" {
        return defaultMaxBytes
    }
    n, err := strconv.ParseInt(v, 10, 64)
    if err != nil || n <= 0 {
        slog.Warn("TEMPORAL_LOG_MAX_BYTES invalid, using default",
            "value", v, "default", defaultMaxBytes)
        return defaultMaxBytes
    }
    return n
}()
```

2. Replace the inline `os.Getenv` + `strconv.ParseInt` block in `runCommand` (lines 968–971) with a reference to `maxLogBytes`.

3. Add a `TestMaxLogBytesDefault` test in `temporal/internal/activities/steps_test.go` that verifies the default is `10000` when the env var is unset.

---

## Acceptance Criteria

1. `grep -n 'TEMPORAL_LOG_MAX_BYTES' temporal/internal/activities/steps.go` returns exactly one line (the package-level initializer).
2. `grep -n 'os.Getenv.*TEMPORAL_LOG_MAX_BYTES' temporal/internal/activities/steps.go` returns empty.
3. `cd temporal && go test ./...` passes.
