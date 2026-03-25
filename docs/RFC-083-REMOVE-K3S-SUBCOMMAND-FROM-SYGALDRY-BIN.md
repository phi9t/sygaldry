# RFC-083: Remove Stale k3s Subcommand from bin/sygaldry

**Status:** Open
**Date:** 2026-03-25
**Priority:** Medium
**Effort:** XS

---

## Problem

`bin/sygaldry` contains a `k3s` subcommand block (lines 92–113) that references
`${SYGALDRY_HOME}/k3s/bin/kentai` and `${SYGALDRY_HOME}/k3s/bin/kjob`. The `k3s/`
directory was deleted by RFC-068 (commit ed74b08). Invoking `sygaldry k3s enter`
or `sygaldry k3s job` now silently falls through to `exec` on a non-existent path,
producing an unhelpful "No such file or directory" error with no diagnostic.

Additionally, `k3s` appears in the tab-completion word list at line 142:
```bash
local subcommands="shell run job config snapshot validate completions version k3s sail --help --repo"
```
and in the completion `case` statement at lines 154–156.

---

## Solution

Remove the `k3s` subcommand block entirely from `bin/sygaldry`:

1. Delete lines 92–113 (the `k3s)` case branch).
2. Remove `k3s` from the `subcommands` variable at line 142.
3. Remove the `k3s)` case branch from the `_sygaldry_completions` function (lines 154–156).

No replacement is needed — the feature was removed with the `k3s/` directory.

---

## Acceptance Criteria

1. `grep -n 'k3s\|kentai\|kjob' bin/sygaldry` returns empty
2. `shellcheck -s bash -S warning bin/sygaldry` passes with no errors
3. `bash -n bin/sygaldry` exits 0 (syntax check)
