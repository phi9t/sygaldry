# RFC-053: Align discover_issues.py Shellcheck Invocation with validate_all.sh

**Status:** Draft — v1
**Date:** 2026-03-22
**Priority:** Low
**Effort:** XS

---

## Problem

`validate_all.sh:314–315` suppresses SC2034 globally when running shellcheck in CI:

```bash
run_check "shellcheck" "${SHELLCHECK}" -s bash -S warning "${shell_files[@]}" \
    -e SC2034 # Ignore unused variable warnings for config constants
```

`tools/agentic/discover_issues.py:246–254` runs shellcheck without any `-e` exclusion:

```python
result = subprocess.run(
    [
        "shellcheck",
        "-f", "json",
        "-S", "warning",
        "--",
        *[str(f) for f in sh_files],
    ],
    ...
)
```

The result is an asymmetry: `validate_all.sh` passes on the SC2034 finding in
`tools/agentic/sail_cron.sh`, but `discover_issues.py` surfaces it as a SAIL issue.
SAIL then spends agent capacity attempting to fix an issue that CI does not flag.

The correct long-term fix is RFC-043 (inline disable in `sail_cron.sh`) + RFC-050
(remove global suppression from `validate_all.sh`). Until those land, the immediate
fix is to align `discover_issues.py` with `validate_all.sh`'s current behavior.

---

## Solution

Add `"-e", "SC2034"` to the shellcheck invocation in `discover_issues.py:246–254`:

```python
result = subprocess.run(
    [
        "shellcheck",
        "-f", "json",
        "-S", "warning",
        "-e", "SC2034",
        "--",
        *[str(f) for f in sh_files],
    ],
    ...
)
```

This is a **temporary alignment** — when RFC-043 and RFC-050 land, the `-e SC2034`
can be removed from both files simultaneously.

Add a comment in the code to make the temporary nature explicit:

```python
# "-e", "SC2034",  # temporary: aligns with validate_all.sh -e SC2034 until RFC-043+050 land
```

---

## Acceptance Criteria

1. `grep -n '"-e", "SC2034"' tools/agentic/discover_issues.py` returns one line (in the shellcheck invocation).
2. Running `python3 tools/agentic/discover_issues.py --sources shellcheck 2>/dev/null | python3 -c "import json,sys; issues=json.load(sys.stdin); assert not any('SC2034' in i['title'] for i in issues), 'SC2034 found'"` exits 0.
3. This RFC should be superseded by RFC-043 + RFC-050 — when both land, remove `-e SC2034` from `discover_issues.py` as well.
