# RFC-066: Drop validate_all.sh launch_container.sh Dependency

**Status:** Draft — v1
**Date:** 2026-03-23
**Priority:** Low
**Effort:** XS
**Blocked By:** RFC-062

---

## Problem

After RFC-062 deletes `container/launch_container.sh`, `validate_all.sh` will break in
two places:

**Line 148** — `--verify-only` mode calls the shim directly:

```bash
if "${SCRIPT_DIR}/container/launch_container.sh" --entrypoint=verify-spack.sh; then
```

**Line 389** — `--multi-repo-unit` mode runs `launch_container_test.sh`, which exists
solely to test the compatibility shim:

```bash
run_check "launch_container_test.sh" bash "${SCRIPT_DIR}/container/launch_container_test.sh"
```

Both callers must be updated before RFC-062 can land without breaking CI.

---

## Solution

### Fix line 148 — replace shim with direct `zephyr` call

```bash
# Before
if "${SCRIPT_DIR}/container/launch_container.sh" --entrypoint=verify-spack.sh; then

# After
if zephyr entrypoint verify-spack; then
```

### Fix line 389 — remove the shim test

The `launch_container_test.sh` file tests that the shim prints its deprecation banner
and delegates correctly. Once the shim is deleted (RFC-062), this test has no subject.
Remove the `run_check` invocation entirely:

```bash
# Delete this block:
if [[ "${MULTI_REPO_UNIT}" == "true" ]]; then
    section "Multi-repo: unit tests"
    run_check "launch_container_test.sh" bash "${SCRIPT_DIR}/container/launch_container_test.sh"
fi
```

If the multi-repo unit test section gains other tests in the future, the section can be
re-added with those tests. For now it is empty after removing the shim test.

---

## Acceptance Criteria

1. `grep -n "launch_container" validate_all.sh` returns 0 matches.
2. `bash -n validate_all.sh` passes.
3. `validate_all.sh --verify-only` exits 0 when the container is available.
