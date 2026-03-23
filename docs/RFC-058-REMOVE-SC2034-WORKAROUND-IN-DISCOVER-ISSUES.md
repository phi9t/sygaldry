# RFC-058: Remove Stale SC2034 Workaround from discover_issues.py

**Status:** Done — SAIL
**Date:** 2026-03-23
**Priority:** Low
**Effort:** XS

---

## Problem

`tools/agentic/discover_issues.py` contained a temporary SC2034 exclusion added to align with
the global `-e SC2034` suppression in `validate_all.sh` while RFC-043 and RFC-050 were pending.
Both RFCs were implemented; the workaround had become a permanent blind spot.

---

## Solution

Removed `"SC2034"` from the excluded shellcheck codes in `discover_issues.py`.

---

## Acceptance Criteria

All met — implemented by SAIL (commit 923b1a1).
