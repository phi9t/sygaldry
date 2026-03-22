# RFC-042: Extract Duplicated envOr Helper to Internal Package

**Status:** Draft — v1
**Date:** 2026-03-22
**Priority:** Medium
**Effort:** S

---

## Problem

`envOr` is defined identically in three separate `cmd/` packages with no shared home:

- `temporal/cmd/orchestrate/main.go:367`
- `temporal/cmd/worker/main.go:201`
- `temporal/cmd/rfc/main.go:177`

Each definition is:

```go
func envOr(key, fallback string) string {
    if v := os.Getenv(key); v != "" {
        return v
    }
    return fallback
}
```

`temporal/cmd/worker/main.go:208` also defines `envOrInt` which has no equivalent in the other two packages but belongs in the same helper group.

The Temporal flag defaults (`"localhost:7233"`, `"default"`, `"orchestration"`) are repeated at:

- `temporal/cmd/orchestrate/main.go:131–133`
- `temporal/cmd/orchestrate/main.go:259–260`
- `temporal/cmd/rfc/main.go:49–51`
- `temporal/cmd/worker/main.go:42–44`

Any change to a default must be made in multiple places.

---

## Solution

Create `temporal/internal/config/env.go` with:

```go
package config

import (
    "os"
    "strconv"
)

const (
    DefaultAddress   = "localhost:7233"
    DefaultNamespace = "default"
    DefaultTaskQueue = "orchestration"
)

func EnvOr(key, fallback string) string {
    if v := os.Getenv(key); v != "" {
        return v
    }
    return fallback
}

func EnvOrInt(key string) (int, bool, error) {
    v := os.Getenv(key)
    if v == "" {
        return 0, false, nil
    }
    n, err := strconv.Atoi(v)
    return n, err == nil, err
}
```

Replace the three `envOr` definitions and the four hardcoded default sites with calls to `config.EnvOr` / the exported constants.

---

## Acceptance Criteria

1. `grep -rn '^func envOr\b' temporal/ --include='*.go'` returns empty.
2. `grep -rn '^func envOrInt\b' temporal/ --include='*.go'` returns empty.
3. `grep -rn '"localhost:7233"' temporal/ --include='*.go' | grep -v '_test.go'` returns empty (all sites use the constant).
4. `cd temporal && go test ./...` passes.
