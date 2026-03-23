# RFC-062: Remove launch_container.sh Shim and Legacy Fallback

**Status:** Draft — v1
**Date:** 2026-03-23
**Priority:** Low
**Effort:** M
**Blocked By:** RFC-059

---

## Problem

RFC-020 replaced the original 646-line `container/launch_container.sh` with a thin shim
that delegates to the `zephyr` binary. RFC-028 made `ContainerJob` prefer `zephyr` and
only fall back to `launch_container.sh` with a warning. The remaining shim and its callers
are now the only thing preventing full removal.

Retaining the shim keeps a dead code path alive in the Go activity, inflates the test
surface with shim-specific test cases, and leaves shell scripts calling an indirection
layer with no value.

Note: `container/verify_preflight.sh` also calls `launch_container.sh` (line 93), which
overlaps with RFC-059's changes to the same file. RFC-059 should land first to avoid
conflicting edits.

---

## Solution

### Delete the shim and its test

```
container/launch_container.sh
container/launch_container_test.sh
```

### Edit `temporal/internal/activities/steps.go`

- Remove the fallback warning log (line 579)
- Remove `launch_container.sh` paths from `resolveContainerLauncher` candidates (lines 664, 670–672)
- Remove the `usesLegacyShim` branch (line 675)

### Edit `temporal/internal/activities/steps_test.go`

- Remove the "falls back to legacy shim" test (lines 115–137)
- Remove the `launch_container.sh` shimPath setup from the "prefers zephyr binary over
  legacy shim" test (lines 84–113); keep the zephyr-preference assertion

### Update remaining callers

Replace `launch_container.sh` calls with direct `zephyr` invocations or remove:

- `container/Makefile:31` — remove `LAUNCHER` variable
- `container/verify_multi_repo_e2e.sh` (7 calls) — replace with `zephyr` equivalent
- `container/verify_preflight.sh:93` — replace with `zephyr`
- `container/snapshot_spack.sh:311,314,317` — update usage messages
- `container/snapshot_mlsys.sh:359` — update usage message
- `container/lib/spack_init.sh:35` — update error message

---

## Acceptance Criteria

1. `grep -rn "launch_container" . --include="*.sh" --include="*.go" --include="*.md"` returns 0 matches (excluding `docs/RFC-*.md` and CLAUDE.md historical references).
2. `cd temporal && go test ./...` passes.
3. `shellcheck -s bash -S warning container/verify_multi_repo_e2e.sh container/verify_preflight.sh container/snapshot_spack.sh` passes.
