# RFC-069: Remove example_repo_scoped_zephyr_skill/ Directory

**Status:** Draft — v1
**Date:** 2026-03-24
**Priority:** Low
**Effort:** XS

---

## Problem

`example_repo_scoped_zephyr_skill/SKILL.md` (97 lines) is an orphaned document at the
repo root. It describes a "Zephyr Container Infrastructure Specification (v2)" as a
template for external consumers. It has zero references from any code, scripts, tests, or
CI — it exists only as an entry in the `DOC_SCOPE` anti-drift check in
`tools/check_zephyr_contracts.sh:54`.

The canonical, maintained version of this documentation is `skills/zephyr/SKILL.md`.
The example directory:
- Contains stale `launch_container.sh` usage examples (RFC-062 removes this file)
- Duplicates content that is better maintained in `skills/zephyr/`
- Is not installed, vendored, or referenced by any consumer
- Was never added to `CLAUDE.md` or the repo structure documentation

---

## Solution

### Delete the directory

```
example_repo_scoped_zephyr_skill/
```

### Update `tools/check_zephyr_contracts.sh`

Remove `"example_repo_scoped_zephyr_skill/SKILL.md"` from the `DOC_SCOPE` array
(line 54). The contract check will continue to cover `skills/zephyr/SKILL.md`,
`skills/nvidia-container-troubleshooting/SKILL.md`, and other active skill docs.

---

## Acceptance Criteria

1. `example_repo_scoped_zephyr_skill/` directory does not exist.
2. `grep -rn "example_repo_scoped_zephyr_skill" .` returns 0 matches (excluding `docs/RFC-*.md`).
3. `bash -n tools/check_zephyr_contracts.sh` passes.
