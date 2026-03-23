# RFC-064: Add `version` Field to Temporal YAML Plan Schema

**Status:** Draft — v1
**Date:** 2026-03-23
**Priority:** Low
**Effort:** S

---

## Problem

The Temporal YAML plan format has no version field. Plans are parsed with the current schema
regardless of when they were written. A breaking schema change (renamed field, new required
field) silently misinterprets old plans at runtime. There is no way to distinguish a v1 plan
from a future v2 plan in logs.

---

## Solution

Add an optional `version` integer field to the plan YAML. Emit a warning (not error) when
absent; error when the version exceeds the supported maximum.

### Schema change

```yaml
version: 1          # plan schema version (optional for v1 backwards compat)
steps:
  - id: my_step
    ...
```

### Loader change (`temporal/internal/plan/loader.go`)

Add `Version int \`yaml:"version"\`` to the `Plan` struct. After loading:

```go
const SupportedPlanVersion = 1

if plan.Version == 0 {
    slog.Warn("plan has no version field; assuming version 1", "file", path)
    plan.Version = 1
}
if plan.Version > SupportedPlanVersion {
    return nil, fmt.Errorf("plan version %d newer than supported %d; upgrade the worker",
        plan.Version, SupportedPlanVersion)
}
```

### Update example files

Add `version: 1` to all `temporal/examples/*.yaml` plan files.

---

## Acceptance Criteria

1. All example YAML files in `temporal/examples/` contain `version: 1`.
2. A plan without `version:` loads successfully with Version set to 1 and logs a warning.
3. A plan with `version: 99` returns an error.
4. `cd temporal && go test ./...` passes with at least two new cases:
   - `TestLoadPlan_MissingVersionDefaults`
   - `TestLoadPlan_FutureVersionReturnsError`
5. `./validate_all.sh --quick` passes.
