# RFC-054: Add `discover_open_rfcs` Source to SAIL Issue Discovery

**Status:** Done — SAIL
**Date:** 2026-03-23
**Priority:** High
**Effort:** S

---

## Problem

`tools/agentic/discover_issues.py` had no RFC source. Open RFCs in `docs/RFC-*.md` had to be
manually injected into SAIL via `--issues-file`. This broke the self-sustaining loop.

---

## Solution

Added `discover_open_rfcs()` to `discover_issues.py` that scans `docs/RFC-INDEX.md` for open
RFC rows and emits them as `type: "rfc"` issues. Registered as `open_rfcs` source.

---

## Acceptance Criteria

All met — implemented by SAIL (commit d845dd8).
