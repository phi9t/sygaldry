# RFC-056: Temporal Worker Startup Config Validation

**Status:** Done — SAIL (commit 2dd7f37)
**Date:** 2026-03-23
**Priority:** Medium
**Effort:** S

---

## Problem

`temporal/cmd/worker/main.go` loads configuration from YAML, environment variables, and CLI
flags, then immediately connects to Temporal — with no explicit validation pass. Misconfigurations
are only surfaced when activities fail at runtime:

- `max_concurrent_activities: 0` causes Temporal SDK to panic or behave unexpectedly.
- An empty `task_queue` causes the worker to register on the wrong queue silently.
- Negative heartbeat or schedule-to-close timeouts are accepted by the config loader but
  rejected later by Temporal at the activity-registration site.
- Invalid `address` formats (e.g. missing port) fail at TCP connect time, producing an opaque
  `dial tcp` error.

---

## Solution

Add a `validateWorkerConfig(cfg WorkerConfig) error` function to `temporal/cmd/worker/main.go`
and call it immediately after config is loaded, before any Temporal client connection.

### Checks to implement

```go
func validateWorkerConfig(cfg WorkerConfig) error {
    var errs []error
    if cfg.TaskQueue == "" {
        errs = append(errs, errors.New("task_queue must not be empty"))
    }
    if cfg.MaxConcurrentActivities < 1 {
        errs = append(errs, fmt.Errorf("max_concurrent_activities must be >= 1 (got %d)", cfg.MaxConcurrentActivities))
    }
    if cfg.MaxConcurrentWorkflowTasks < 1 {
        errs = append(errs, fmt.Errorf("max_concurrent_workflow_tasks must be >= 1 (got %d)", cfg.MaxConcurrentWorkflowTasks))
    }
    if cfg.Address == "" {
        errs = append(errs, errors.New("temporal address must not be empty"))
    } else if !strings.Contains(cfg.Address, ":") {
        errs = append(errs, fmt.Errorf("temporal address %q must be host:port", cfg.Address))
    }
    return errors.Join(errs...)
}
```

Call site in `run()`:

```go
if err := validateWorkerConfig(cfg); err != nil {
    return fmt.Errorf("invalid worker configuration: %w", err)
}
```

---

## Acceptance Criteria

1. Starting the worker with `max_concurrent_activities: 0` in config exits non-zero with a
   clear error before attempting Temporal connection.
2. Starting with an address missing the port exits non-zero.
3. `cd temporal && go test ./cmd/worker/...` passes with at least two new test cases:
   - `TestValidateWorkerConfig_InvalidConcurrency`
   - `TestValidateWorkerConfig_MissingPort`
4. `./validate_all.sh --quick` passes.
