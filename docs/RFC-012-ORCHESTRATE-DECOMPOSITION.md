# RFC-012: Orchestrate Command Decomposition

**Status:** Proposed
**File:** `temporal/cmd/orchestrate/main.go`

---

## Problem

`temporal/cmd/orchestrate/main.go` is 1003 lines long and conflates four distinct
responsibilities in a single package:

1. **CLI dispatch** (`run`, `validate`, `status` subcommands) — lines 110–141
2. **YAML loading and template resolution** — lines 347–441
3. **Merge functions** — 13 merge helpers spanning lines 444–784,
   totalling approximately 340 lines of near-identical boilerplate
4. **Plan validation** — `validatePlan` (lines 786–884) with cycle detection
   (lines 886–952), stopping on the first error encountered

The file has grown to the point where adding a new step type requires changes in
three locations: the `allowedTypes` map, a new `case` in `validatePlan`'s type
switch, and a new `mergeXxxSpec` function.

---

## Key Findings

### 13 merge functions with identical structure

Every spec-level merge function follows the same pattern: nil-guard the base
pointer, copy it, overwrite each non-zero field:

```go
// temporal/cmd/orchestrate/main.go:539-554
func mergeDownloadSpec(base, override *workflows.DownloadSpec) *workflows.DownloadSpec {
    if base == nil {
        base = &workflows.DownloadSpec{}
    }
    merged := *base
    if override.URL != "" {
        merged.URL = override.URL
    }
    if override.Output != "" {
        merged.Output = override.Output
    }
    if override.Sha256 != "" {
        merged.Sha256 = override.Sha256
    }
    return &merged
}
```

All 13 functions (`mergeRetrySpec`, `mergeDownloadSpec`, `mergeDockerBuildSpec`,
`mergeDockerPushSpec`, `mergePackageBuildSpec`, `mergeContainerJobSpec`,
`mergeHFDownloadDatasetSpec`, `mergeHFDownloadModelSpec`, `mergeK8sJobSpec`,
`mergeAgentTaskSpec`, `mergeGitOpSpec`, `mergeStringMaps`, and the dispatcher
`mergePipelineStep`) repeat this structure. The central dispatcher
`mergePipelineStep` (lines 444–517) manually calls each one.

### Validation stops on first error

`validatePlan` returns on the first `fmt.Errorf` it encounters:

```go
// temporal/cmd/orchestrate/main.go:786-803
func validatePlan(input *workflows.PipelineInput) error {
    if len(input.Steps) == 0 {
        return fmt.Errorf("plan must have at least one step")
    }

    ids := map[string]bool{}
    for i := range input.Steps {
        step := &input.Steps[i]
        if step.ID == "" {
            return fmt.Errorf("step %d is missing id", i)
        }
        if ids[step.ID] {
            return fmt.Errorf("duplicate step id: %s", step.ID)
        }
        ...
```

A plan with 5 missing IDs reports only the first. The user must fix and re-run
to discover subsequent errors. This is addressed in RFC-018.

### YAML loading mixed into main package

`loadPipelinePlan`, `decodeYAMLStrict`, `loadTemplateImport`, and
`resolveStepTemplates` (lines 347–441) live in `main` with no test coverage
from a library perspective; they are only tested indirectly via integration.

---

## Proposed Changes

### 1. Extract `internal/plan/` package

Create three files under `temporal/internal/plan/`:

**`loader.go`** — YAML loading and template resolution:
- `Load(planPath string) (workflows.PipelineInput, error)`
- `decodeYAMLStrict`, `loadTemplateImport`, `resolveStepTemplates`

**`validator.go`** — plan validation:
- `Validate(input *workflows.PipelineInput) error` (see RFC-018 for multi-error
  variant)
- `detectDependencyCycle`, `renderCycle`

**`merger.go`** — template merging:
- `MergeStep(base, override workflows.PipelineStep) workflows.PipelineStep`
- Replace the 11 type-specific helpers with a single reflect-based helper:

```go
// mergeSpec merges two spec pointers of the same type T.
// For each exported string/bool/int field in override, if the value is
// non-zero it overwrites the corresponding field in base.
func mergeSpec[T any](base, override *T) *T {
    if base == nil {
        base = new(T)
    }
    merged := *base
    // reflect over override fields, copy non-zero values
    ...
    return &merged
}
```

Map merging (for `Env`, `BuildArgs`, `Labels`, `Params`) stays as explicit
calls to `mergeStringMaps` since reflect does not distinguish empty-map from
nil.

### 2. Simplify `cmd/orchestrate/main.go`

After extraction, `main.go` shrinks to:
- Flag parsing for each subcommand
- Calls to `plan.Load`, `plan.Validate`, Temporal client construction
- Output serialization (`printOutput`)
- Manifest writing (`writePlanManifest`)

Estimated result: ~350 lines.

### 3. Move `allowedTypes` to `validator.go`

The `allowedTypes` map (lines 24–36) belongs with validation logic, not with
CLI dispatch.

---

## Files Changed

| File | Action |
|------|--------|
| `temporal/cmd/orchestrate/main.go` | Shrink to CLI dispatch + output |
| `temporal/internal/plan/loader.go` | New — YAML loading, template resolution |
| `temporal/internal/plan/validator.go` | New — validation, cycle detection, `allowedTypes` |
| `temporal/internal/plan/merger.go` | New — reflect-based merge helper |
| `temporal/internal/plan/loader_test.go` | New — unit tests for loader |
| `temporal/internal/plan/validator_test.go` | New — unit tests for validator |

---

## Verification

```bash
cd temporal
go build ./...
go test ./...
go run ./cmd/orchestrate validate -plan examples/pipeline.yaml
```

All existing tests in `cmd/orchestrate/` must continue to pass without
modification.
