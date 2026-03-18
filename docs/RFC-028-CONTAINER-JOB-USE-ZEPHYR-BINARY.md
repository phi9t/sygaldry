# RFC-028: ContainerJob Activity Should Use the zephyr Binary

**Status:** Proposed
**Priority:** High
**Effort:** S
**Area:** temporal / rust-core

## Problem

The `ContainerJob` Temporal activity in `temporal/internal/activities/steps.go` resolves the container launcher via `resolveContainerLauncherPath()`, which finds `container/launch_container.sh`. The Rust `zephyr` binary is the canonical launcher (RFC-002, RFC-020) and has a superset of the bash script's capabilities. Using the shell script means:

- The activity runs a 550-line bash script on every container job invocation.
- Any bug fixed in the Rust binary is not reflected in Temporal pipeline runs.
- The `PYTHON_VERSION` discrepancy (RFC-025) affects every `container_job` pipeline step.

## Evidence

`temporal/internal/activities/steps.go` — `resolveContainerLauncherPath()` function:
```go
func resolveContainerLauncherPath() string {
    // checks SYGALDRY_HOME, then relative paths, eventually:
    return filepath.Join(sygaldryHome, "container", "launch_container.sh")
}
```

`ContainerJob()` calls `resolveContainerLauncherPath()` and passes the result as the command to execute.

## Proposed Changes

1. Update `resolveContainerLauncherPath()` (or replace it with `resolveZephyrBinaryPath()`) to search for the `zephyr` binary:
   - `$SYGALDRY_HOME/target/release/zephyr`
   - `$SYGALDRY_HOME/crates/zephyr/target/release/zephyr`
   - `$(which zephyr)` (if installed to PATH)
   - Fall back to `container/launch_container.sh` only if none found (with a warning log).

2. Rename the function to `resolveContainerLauncher()` and return both the path and a flag indicating whether the fallback was used, so the fallback can be logged as a warning.

3. Add an `activityLogger.Warn()` call when the bash shim fallback is triggered.

## Files Changed

- `temporal/internal/activities/steps.go` — `resolveContainerLauncherPath()` → `resolveContainerLauncher()`

## Verification

```bash
cd temporal && go build ./...
go test ./internal/activities/...
# Integration: set SYGALDRY_HOME to repo root, run a ContainerJob activity,
# verify the zephyr binary is invoked (check log or strace).
```
