# RFC-043: Suppress SC2034 False Positive in sail_cron.sh

**Status:** Draft — v2
**Date:** 2026-03-22
**Priority:** Medium
**Effort:** XS

---

## Problem

`shellcheck -s bash -S warning tools/agentic/sail_cron.sh` emits:

```
In tools/agentic/sail_cron.sh line 11:
readonly CONFIG_FILE
         ^---------^ SC2034 (warning): CONFIG_FILE appears unused.
```

`CONFIG_FILE` is declared at `tools/agentic/sail_cron.sh:10–11`:

```bash
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
readonly CONFIG_FILE
```

It IS consumed by `tools/agentic/lib/sail_config.sh:5`:

```bash
local config_file="${CONFIG:-${CONFIG_FILE:-}}"
```

ShellCheck cannot track cross-file variable usage through `source`, so the warning is a false positive.

**Note:** `validate_all.sh:315` suppresses SC2034 globally via `-e SC2034` across all shell files,
so the CI run is currently clean. However:
1. The standalone shellcheck invocation (`shellcheck -s bash -S warning tools/agentic/sail_cron.sh`) still emits the warning.
2. The global suppression in `validate_all.sh` hides all SC2034 findings, including real unused-variable bugs in other shell scripts. RFC-050 addresses that broader issue.

This RFC fixes `sail_cron.sh` so the global suppression can eventually be removed.

---

## Solution

Add an inline disable comment on `tools/agentic/sail_cron.sh:11` to suppress the false positive:

```bash
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
# shellcheck disable=SC2034  # used by sourced lib/sail_config.sh
readonly CONFIG_FILE
```

No logic changes. The comment documents why the variable appears unused to shellcheck.

---

## Acceptance Criteria

1. `shellcheck -s bash -S warning tools/agentic/sail_cron.sh` exits 0 with no output.
2. `grep 'shellcheck disable=SC2034' tools/agentic/sail_cron.sh` returns the new line.
3. This RFC is a prerequisite for RFC-050 (remove global SC2034 suppression from validate_all.sh).
