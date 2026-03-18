# RFC-005: Dead Code Purge

**Status:** Draft — v1
**Date:** 2026-03-16
**Priority:** Immediate — zero risk, instant simplification

---

## 1. Problem

Three blocks of confirmed dead code compile into every build and register into every worker:

### 1.1 `temporal/cmd/run/main.go` (87 LOC)

Legacy workflow runner. Takes a JSON input file and submits `workflows.Orchestrate`. Superseded by `cmd/orchestrate` (the YAML-based pipeline runner). Nothing in the repo calls `cmd/run` — not `Makefile`, not `bin/sygaldry`, not any pipeline YAML.

```
$ grep -r "cmd/run" temporal/ --include="*.go" --include="*.sh" --include="*.yaml"
(no results outside cmd/run itself)
```

### 1.2 `temporal/internal/workflows/orchestration.go` (138 LOC)

The `Orchestrate` workflow and its supporting types (`Step`, `OrchestrationInput`, `StepResult`, `OrchestrationResult`). Only used by `cmd/run`. The `Pipeline` workflow in `pipeline.go` is the active implementation — it handles dependency graphs, when-clauses, 10 step types, and retries. `Orchestrate` only handles sequential linear steps with `allowFailure`.

### 1.3 `temporal/cmd/worker/main.go:44` — dead workflow registration

```go
w.RegisterWorkflow(workflows.Orchestrate)  // line 44
```

Registering a dead workflow adds it to the Temporal namespace registry and can cause confusion when inspecting available workflow types.

---

## 2. Changes

### Delete `temporal/cmd/run/`
```bash
git rm -r temporal/cmd/run/
```

### Delete `temporal/internal/workflows/orchestration.go`
```bash
git rm temporal/internal/workflows/orchestration.go
```

### Remove registration from `temporal/cmd/worker/main.go:44`

```go
// DELETE:
w.RegisterWorkflow(workflows.Orchestrate)
```

The `workflows` import remains valid because `workflows.Pipeline` is still on line 45.

---

## 3. Pre-deletion checks

```bash
cd temporal

# Confirm nothing outside cmd/run uses orchestration types
grep -r "OrchestrationInput\|OrchestrationResult\|workflows\.Orchestrate" \
    --include="*.go" \
    --exclude-dir="cmd/run" \
    --exclude="orchestration.go"
# Expected: no matches

# Confirm cmd/run is not referenced in go.work or any build script
grep -r "cmd/run" .. --include="*.sh" --include="*.yaml" --include="Makefile"
# Expected: no matches

# Build and test
go build ./...
go test ./...
```

---

## 4. Verification

```bash
cd temporal && go build ./... && go test ./...
# Expected: clean build, all tests pass
# Expected: no reference to Orchestrate in binary's registered workflows
```

Line count reduction: **225 LOC deleted**.

---

## 5. Risk Register

| Risk | Severity | Mitigation |
|------|----------|-----------|
| External code calls `cmd/run` directly | Near-zero | Nothing in repo references it; it was a dev tool |
| `Orchestrate` workflow has live executions in Temporal | Low | Dev server only; `temporal workflow list` to confirm none running |
| `StepResult` type name collision with pipeline.go | None | `pipeline.go` uses `PipelineStepResult` — distinct name |
