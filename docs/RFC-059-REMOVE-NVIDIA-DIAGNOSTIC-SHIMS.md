# RFC-059: Remove Deprecated NVIDIA Diagnostic Shims

**Status:** Draft — v1
**Date:** 2026-03-23
**Priority:** Low
**Effort:** XS

---

## Problem

Two shell scripts in `container/` are pure deprecation shims that print a warning and exit:

- `container/inspect_nvidia_setup.sh` — prints a deprecation warning; replaced by `container/diagnose_nvidia.sh`
- `container/fix_nvidia_setup.sh` — prints a deprecation warning; replaced by `container/diagnose_nvidia.sh --fix`

These files exist solely because `container/verify_preflight.sh:72` still calls
`inspect_nvidia_setup.sh` directly. No other callers exist. The shims add dead surface
area and can mislead future contributors into thinking they carry logic.

---

## Solution

### Delete the shims

```
container/inspect_nvidia_setup.sh
container/fix_nvidia_setup.sh
```

### Update `container/verify_preflight.sh:72`

Replace the `inspect_nvidia_setup.sh` call with a direct `diagnose_nvidia.sh` invocation:

```bash
# Before
"${SCRIPT_DIR}/inspect_nvidia_setup.sh"

# After
"${SCRIPT_DIR}/diagnose_nvidia.sh"
```

---

## Acceptance Criteria

1. Both files deleted; `git status` shows no `inspect_nvidia_setup.sh` or `fix_nvidia_setup.sh`.
2. `grep -r "inspect_nvidia_setup\|fix_nvidia_setup" . --include="*.sh" --include="*.md"` returns 0 matches.
3. `bash -n container/verify_preflight.sh` passes.
