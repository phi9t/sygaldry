# RFC-060: Remove Deprecated Autobuild/Autoretry Shell Scripts

**Status:** Draft — v1
**Date:** 2026-03-23
**Priority:** Low
**Effort:** S

---

## Problem

Three shell scripts in `tools/` were deprecated on 2026-03-06 when the Temporal pipeline
took over Spack build orchestration:

- `tools/zephyr_autobuild.sh` — DEPRECATED 2026-03-06; replaced by Temporal pipeline
- `tools/zephyr_autoretry.sh` — DEPRECATED 2026-03-06
- `tools/zephyr_autoretry_tmux.sh` — DEPRECATED 2026-03-06

`container/verify_build.sh` still invokes `zephyr_autobuild.sh` via `--autoretry`, and
`CLAUDE.md` still documents all three scripts. Retaining deprecated entry points creates
confusion about the canonical build path.

---

## Solution

### Delete the deprecated scripts

```
tools/zephyr_autobuild.sh
tools/zephyr_autoretry.sh
tools/zephyr_autoretry_tmux.sh
```

### Migrate `container/verify_build.sh`

Replace the `zephyr_autobuild.sh` invocation with a direct Temporal pipeline call
(Temporal handles retries internally, so `--autoretry` is not needed):

```bash
exec go -C "${ROOT}/temporal" run ./cmd/orchestrate run \
    -plan examples/spack-build-pipeline.yaml
```

### Update `CLAUDE.md`

Remove the three autobuild/autoretry lines from the "Automated Spack builds with retry"
section (lines 117–119) and the `zephyr_autobuild.sh` entry in the repo structure section
(line 264).

### Update `temporal/examples/spack-build-pipeline.yaml:4`

The comment "Replaces zephyr_autobuild.sh / zephyr_autoretry.sh" can be updated to past
tense to reflect that replacement is complete.

---

## Acceptance Criteria

1. Three files deleted; `grep -r "zephyr_autobuild\|zephyr_autoretry" . --include="*.sh"` returns 0 matches (excluding the yaml comment).
2. `bash -n container/verify_build.sh` passes.
3. `validate_all.sh` shellcheck section passes.
