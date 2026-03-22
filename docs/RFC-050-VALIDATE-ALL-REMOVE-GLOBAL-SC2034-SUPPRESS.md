# RFC-050: Remove Global SC2034 Suppression from validate_all.sh

**Status:** Draft — v1
**Date:** 2026-03-22
**Priority:** Medium
**Effort:** S

---

## Problem

`validate_all.sh:315` suppresses SC2034 globally across every shell script in the repository:

```bash
run_check "shellcheck" "${SHELLCHECK}" -s bash -S warning "${shell_files[@]}" \
    -e SC2034 # Ignore unused variable warnings for config constants
```

SC2034 ("variable appears unused") is one of shellcheck's most useful correctness warnings.
The global `-e SC2034` flag hides real bugs in any shell script — not just the known false
positive in `tools/agentic/sail_cron.sh`.

Concrete risk: any future shell script that declares a variable and forgets to use it (a
copy-paste error, a renamed variable left behind, a silent typo in a variable name) will
pass CI silently.

The false positive that motivated this suppression is `CONFIG_FILE` in
`tools/agentic/sail_cron.sh:11` (the variable is used by a sourced script that shellcheck
cannot see). RFC-043 addresses that false positive at its source by adding an inline
`# shellcheck disable=SC2034` comment.

---

## Solution

After RFC-043 lands (inline disable comment in `sail_cron.sh`), remove the `-e SC2034`
flag from `validate_all.sh:315`:

```bash
# before
run_check "shellcheck" "${SHELLCHECK}" -s bash -S warning "${shell_files[@]}" \
    -e SC2034 # Ignore unused variable warnings for config constants

# after
run_check "shellcheck" "${SHELLCHECK}" -s bash -S warning "${shell_files[@]}"
```

Remove the now-stale comment as well.

---

## Acceptance Criteria

1. `grep 'SC2034' validate_all.sh` returns empty (no global suppression remains).
2. `./validate_all.sh` (full run) exits 0 with shellcheck passing.
3. `shellcheck -s bash -S warning tools/agentic/sail_cron.sh` exits 0 (RFC-043 landed).
4. RFC-043 must be implemented before this RFC.
