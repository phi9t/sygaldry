# RFC-071: Deduplicate client.Dial in cmd/ Packages

**Status:** Draft — v1
**Date:** 2026-03-24
**Priority:** Medium
**Effort:** XS

---

## Problem

`client.Dial(client.Options{HostPort: ..., Namespace: ...})` + error check appears in
4 places across 3 `cmd/` packages:

- `temporal/cmd/orchestrate/main.go:173` — `runPipeline`
- `temporal/cmd/orchestrate/main.go:271` — `queryPipeline`
- `temporal/cmd/rfc/main.go:118` — `runRFC`
- `temporal/cmd/worker/main.go:145` — startup (uses cfg fields instead of flag pointers)

The first three are identical. The fourth differs only in error handling (uses `slog.Error`
+ `os.Exit` instead of returning the error). Each call site duplicates the same 3-line
dial + error-wrap pattern. Any change to Temporal client options (e.g., adding TLS) must
be applied in 4 places.

---

## Solution

Add a `dialClient` helper to a new file `temporal/cmd/internal/dial.go`:

```go
package cmdinternal

import (
    "fmt"
    "go.temporal.io/sdk/client"
)

// DialClient creates a Temporal client and wraps any error with context.
func DialClient(hostPort, namespace string) (client.Client, error) {
    c, err := client.Dial(client.Options{HostPort: hostPort, Namespace: namespace})
    if err != nil {
        return nil, fmt.Errorf("unable to connect to Temporal at %s: %w", hostPort, err)
    }
    return c, nil
}
```

Replace each call site:

```go
// Before
c, err := client.Dial(client.Options{HostPort: *address, Namespace: *namespace})
if err != nil {
    return fmt.Errorf("unable to create Temporal client: %w", err)
}

// After
c, err := cmdinternal.DialClient(*address, *namespace)
if err != nil {
    return err
}
```

The worker startup keeps its `slog.Error` + `os.Exit` pattern but delegates the dial:

```go
c, err := cmdinternal.DialClient(cfg.Address, cfg.Namespace)
if err != nil {
    slog.Error("unable to create Temporal client", "error", err)
    os.Exit(1)
}
```

---

## Acceptance Criteria

1. `grep -rn 'client\.Dial(' temporal/cmd/ --include="*.go"` returns 0 matches.
2. `cd temporal && go build ./...` passes.
3. `cd temporal && go test ./...` passes.
