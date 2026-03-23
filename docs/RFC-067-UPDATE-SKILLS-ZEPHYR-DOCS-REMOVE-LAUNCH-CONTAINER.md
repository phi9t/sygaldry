# RFC-067: Update skills/zephyr Documentation to Reference zephyr Binary

**Status:** Draft — v1
**Date:** 2026-03-23
**Priority:** Low
**Effort:** S
**Blocked By:** RFC-062

---

## Problem

`skills/zephyr/SKILL.md` documents the container infrastructure for external repos using
`container/launch_container.sh` throughout. After RFC-062 deletes the shim, any user or
agent following this documentation will encounter a missing file.

Affected lines in `skills/zephyr/SKILL.md`:

```
Line 13: "Use container/launch_container.sh to..."
Line 39: ./container/launch_container.sh
Line 42: ./container/launch_container.sh -- python train.py
Line 45: ./container/launch_container.sh --repo /path/to/my-project -- python train.py
Line 48: ./container/launch_container.sh --entrypoint verify-gpu.sh
Line 51: ./container/launch_container.sh --entrypoint hf-download.sh -- model Qwen/Qwen3-0.6B-Base
Line 118: ./container/launch_container.sh --entrypoint verify-gpu.sh
Line 119: ./container/launch_container.sh --entrypoint verify-spack.sh
```

Additionally, `skills/zephyr/scripts/run_specdec.sh:9` uses:

```bash
launcher="${SYGALDRY_LAUNCHER:-container/launch_container.sh}"
```

---

## Solution

### Update `skills/zephyr/SKILL.md`

Replace all `./container/launch_container.sh` references with the equivalent `zephyr`
invocations:

| Old | New |
|-----|-----|
| `./container/launch_container.sh` | `zephyr shell` |
| `./container/launch_container.sh -- <cmd>` | `zephyr shell -- <cmd>` |
| `./container/launch_container.sh --repo <path> -- <cmd>` | `zephyr shell --repo <path> -- <cmd>` |
| `./container/launch_container.sh --entrypoint verify-gpu.sh` | `zephyr entrypoint verify-gpu` |
| `./container/launch_container.sh --entrypoint verify-spack.sh` | `zephyr entrypoint verify-spack` |
| `./container/launch_container.sh --entrypoint hf-download.sh -- model <id>` | `zephyr entrypoint hf-download -- model <id>` |

Update the introductory paragraph (line 13) to reference `zephyr shell` or `bin/sygaldry`
as the entry point.

### Update `skills/zephyr/scripts/run_specdec.sh:9`

Replace the hardcoded shim default:

```bash
# Before
launcher="${SYGALDRY_LAUNCHER:-container/launch_container.sh}"

# After
launcher="${SYGALDRY_LAUNCHER:-zephyr}"
```

---

## Acceptance Criteria

1. `grep -n "launch_container" skills/zephyr/SKILL.md skills/zephyr/scripts/run_specdec.sh` returns 0 matches.
2. `shellcheck -s bash -S warning skills/zephyr/scripts/run_specdec.sh` passes.
