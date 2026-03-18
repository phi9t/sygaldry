# RFC-018: Temporal Plan Validation Multi-Error Reporting

**Status:** Proposed
**File:** `temporal/cmd/orchestrate/main.go`

---

## Problem

`validatePlan` returns on the first error it encounters. When a pipeline YAML
has multiple problems — missing IDs, wrong types, unresolved dependencies — the
user must fix and re-run repeatedly to discover each issue. Collecting all errors
and reporting them together would eliminate this round-trip friction.

---

## Key Findings

### Current implementation stops on first error

`validatePlan` (lines 786–884) uses early returns throughout its validation loop:

```go
// temporal/cmd/orchestrate/main.go:786-812
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
        ids[step.ID] = true
        if step.Type == "" {
            return fmt.Errorf("step %s is missing type", step.ID)
        }
        if !allowedTypes[step.Type] {
            return fmt.Errorf("step %s has unsupported type %s", step.ID, step.Type)
        }
```

The pattern continues into the type-specific required-field checks (lines
810–861) and the dependency/when-clause checks (lines 864–878). Every
`fmt.Errorf` is a `return`, so the caller sees at most one error per invocation.

For a 10-step plan where steps 2, 5, and 8 each have a missing `type`, the user
sees only the error from step 2. After fixing it and re-running, they see the
error from step 5, and so on.

### Dependency checks cannot safely run before ID checks

Some validation passes have ordering constraints. Dependency resolution (lines
864–878) references `ids` which is only complete after the ID uniqueness pass.
The cycle detection (line 880) requires all dependency edges to be valid.

The multi-error approach must preserve this ordering: collect errors from the
per-step pass first, and only proceed to dependency and cycle checks if the
per-step pass found no ID/duplicate errors (since those would make the
dependency check unreliable).

### `errors.Join` is available in Go 1.20+

The module already imports `"errors"` (line 7). `errors.Join` (Go 1.20) accepts
a variadic `[]error` and returns a single error whose `.Error()` method
concatenates all non-nil messages with newlines:

```go
err := errors.Join(err1, err2, err3)
// err.Error() == "message1\nmessage2\nmessage3"
```

`errors.Join` returns `nil` if all inputs are `nil`, so the call site needs no
special handling when there are no errors.

---

## Proposed Changes

### Change `validatePlan` to collect `[]error`

Replace each `return fmt.Errorf(...)` within the per-step loop with an append
to an error slice. After the per-step loop, if any errors were collected, join
and return them. Only proceed to dependency and cycle checks when the per-step
pass is clean.

```go
func validatePlan(input *workflows.PipelineInput) error {
    if len(input.Steps) == 0 {
        return fmt.Errorf("plan must have at least one step")
    }

    var errs []error
    ids := map[string]bool{}

    for i := range input.Steps {
        step := &input.Steps[i]
        if step.ID == "" {
            errs = append(errs, fmt.Errorf("step %d is missing id", i))
            continue // cannot use step.ID below if it is empty
        }
        if ids[step.ID] {
            errs = append(errs, fmt.Errorf("duplicate step id: %s", step.ID))
        }
        ids[step.ID] = true
        if step.Type == "" {
            errs = append(errs, fmt.Errorf("step %s is missing type", step.ID))
        } else if !allowedTypes[step.Type] {
            errs = append(errs, fmt.Errorf("step %s has unsupported type %s", step.ID, step.Type))
        } else {
            // type-specific required field checks
            switch step.Type {
            case "command":
                if step.Command == "" {
                    errs = append(errs, fmt.Errorf("step %s command is required", step.ID))
                }
            // ... all other cases ...
            }
        }
        if step.Name == "" {
            step.Name = step.ID
        }
    }

    // Only check dependencies when the ID pass is clean.
    // Dependency checks rely on the ids map being complete and correct.
    if len(errs) == 0 {
        for _, step := range input.Steps {
            for _, dep := range step.DependsOn {
                if !ids[dep] {
                    errs = append(errs, fmt.Errorf("step %s depends on unknown step %s", step.ID, dep))
                }
            }
            if step.When != nil {
                if step.When.Step == "" || (step.When.Status != "success" && step.When.Status != "failure") {
                    errs = append(errs, fmt.Errorf("step %s has invalid when condition", step.ID))
                } else if !ids[step.When.Step] {
                    errs = append(errs, fmt.Errorf("step %s when references unknown step %s", step.ID, step.When.Step))
                }
            }
        }

        if len(errs) == 0 {
            if cycle := detectDependencyCycle(input.Steps); cycle != "" {
                errs = append(errs, fmt.Errorf("dependency cycle detected: %s", cycle))
            }
        }
    }

    return errors.Join(errs...)
}
```

### Update call sites

Both `runCommand` (line 185) and `validateCommand` (line 254) wrap the result
with `fmt.Errorf("plan validation failed: %w", err)`. No change is needed at
the call sites; `errors.Join` returns a single `error` value that wraps all
collected errors.

### Update test expectations

Tests in `cmd/orchestrate/` that assert on specific error messages when a plan
has a single invalid step are unaffected. Tests that previously tested "first
error wins" behaviour in multi-error scenarios must be updated to assert that
all expected errors are present in the joined message.

Example before:
```go
err := validatePlan(&input)
assert.ErrorContains(t, err, "step foo is missing type")
```

Example after (when the test plan intentionally has multiple errors):
```go
err := validatePlan(&input)
assert.ErrorContains(t, err, "step foo is missing type")
assert.ErrorContains(t, err, "step bar is missing type")
```

---

## Files Changed

| File | Action |
|------|--------|
| `temporal/cmd/orchestrate/main.go` | Refactor `validatePlan` to collect `[]error`, return via `errors.Join` |
| `temporal/cmd/orchestrate/main_test.go` | Update any tests that relied on single-error short-circuit behaviour |

---

## Verification

```bash
cd temporal
go build ./cmd/orchestrate
go test ./cmd/orchestrate/... -v -run TestValidatePlan
```

Add a test case with a plan containing multiple distinct errors and assert that
all errors appear in the returned message:

```go
// All three errors should be reported together, not one at a time
steps := []workflows.PipelineStep{
    {ID: "a"},                             // missing type
    {ID: "b", Type: "command"},            // missing command
    {ID: "c", Type: "invalid_type_xyz"},   // unsupported type
}
err := validatePlan(&workflows.PipelineInput{Steps: steps})
assert.ErrorContains(t, err, "step a is missing type")
assert.ErrorContains(t, err, "step b command is required")
assert.ErrorContains(t, err, "step c has unsupported type invalid_type_xyz")
```

Run the full test suite to confirm no regressions:

```bash
go test -C temporal -count=1 ./...
```
