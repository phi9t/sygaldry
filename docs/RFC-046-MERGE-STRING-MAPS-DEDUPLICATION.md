# RFC-046: Extract Duplicated mergeStringMaps Helper to Internal Package

**Status:** Draft — v1
**Date:** 2026-03-22
**Priority:** Low
**Effort:** S

---

## Problem

`mergeStringMaps` is defined identically (modulo style) in two separate packages with no shared home:

- `temporal/internal/workflows/pipeline.go:697`
- `temporal/internal/plan/merger.go:85`

The `pipeline.go` definition:

```go
func mergeStringMaps(base map[string]string, override map[string]string) map[string]string {
    result := cloneMap(base)
    for k, v := range override {
        result[k] = v
    }
    return result
}
```

The `merger.go` definition:

```go
func mergeStringMaps(base map[string]string, override map[string]string) map[string]string {
    result := map[string]string{}
    for key, value := range base {
        result[key] = value
    }
    for key, value := range override {
        result[key] = value
    }
    return result
}
```

Both implement the same semantics (override keys win). Any future change to the merge behavior must be applied twice, and the slight implementation difference (one uses a `cloneMap` helper, the other does not) is a latent inconsistency risk.

Because `merger.go` lives in `internal/plan` and `pipeline.go` lives in `internal/workflows`, neither package can import the other without a circular dependency. The fix is to move the shared helper to a new `temporal/internal/maputil` package that both can import.

---

## Solution

1. Create `temporal/internal/maputil/maps.go`:

```go
package maputil

// MergeStringMaps returns a new map containing all keys from base, with keys
// from override taking precedence.
func MergeStringMaps(base, override map[string]string) map[string]string {
    result := make(map[string]string, len(base)+len(override))
    for k, v := range base {
        result[k] = v
    }
    for k, v := range override {
        result[k] = v
    }
    return result
}
```

2. In `temporal/internal/workflows/pipeline.go`: remove the local `mergeStringMaps` definition (line 697) and replace all call sites with `maputil.MergeStringMaps`.

3. In `temporal/internal/plan/merger.go`: remove the local `mergeStringMaps` definition (line 85) and replace all call sites with `maputil.MergeStringMaps`.

---

## Acceptance Criteria

1. `grep -rn '^func mergeStringMaps\b' temporal/ --include='*.go'` returns empty.
2. `grep -rn 'maputil\.MergeStringMaps' temporal/ --include='*.go' | grep -v '_test.go'` returns at least two lines.
3. `cd temporal && go test ./...` passes.
