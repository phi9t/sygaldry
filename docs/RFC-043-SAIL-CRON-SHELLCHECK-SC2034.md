# RFC-043: Suppress SC2034 False Positive in sail_cron.sh

**Status:** Draft — v1
**Date:** 2026-03-22
**Priority:** Low
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

ShellCheck cannot track cross-file variable usage through `source`, so the warning is a false positive. However, the CI shellcheck step runs at warning level (`-S warning`) and this spurious finding obscures real issues.

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
