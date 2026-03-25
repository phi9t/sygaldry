# RFC-079: Extract HttpServer Class from sail_supervisor.py

**Status:** Open
**Date:** 2026-03-25
**Priority:** Medium
**Effort:** M

---

## Problem

`tools/agentic/sail_supervisor.py` is 1019 lines. Lines 590–743 contain the
`HttpServer` class (~154 lines) that handles health/status HTTP serving. This
class has no cross-dependencies with the supervisor state machine logic — it
only depends on `Config` and `threading.Event`.

Mixing HTTP serving into the supervisor module makes both harder to test and
read independently.

---

## Solution

Create `tools/agentic/sail_http_server.py` and move the `HttpServer` class
(including its `Handler` inner class and all methods) into it.

`HttpServer` references three module-level globals defined at the top of
`sail_supervisor.py` (`_http_lock`, `_current_snapshot`, `_refresh_event`) and
the helper function `safe_json_load`. These must be moved to
`sail_http_server.py` as well, then imported back into `sail_supervisor.py`.

**`tools/agentic/sail_http_server.py` must contain:**
- The three shared globals: `_http_lock`, `_current_snapshot`, `_refresh_event`
- `safe_json_load` (currently at `sail_supervisor.py` line 186)
- The `HttpServer` class (lines 590–742)
- All necessary imports (at minimum: `json`, `threading`, `Path`, `Any`,
  `BaseHTTPRequestHandler`, `HTTPServer as _HTTPServer`, `parse_qs`, `urlparse`)
- The `Config` type must be importable — use `from __future__ import annotations`
  plus a `TYPE_CHECKING` guard to avoid circular imports:
  ```python
  from __future__ import annotations
  from typing import TYPE_CHECKING
  if TYPE_CHECKING:
      from sail_supervisor import Config
  ```

**`sail_supervisor.py` changes:**
1. Remove the `HttpServer` class definition (lines 590–742).
2. Remove `safe_json_load` (line 186) and the three globals (lines 55–57).
3. Replace with:
   ```python
   from sail_http_server import (
       HttpServer,
       safe_json_load,
       _current_snapshot,
       _http_lock,
       _refresh_event,
   )
   ```
   Note: because `main()` at line 871 writes `global _current_snapshot`, that
   line must become `import sail_http_server` and the write changed to
   `sail_http_server._current_snapshot = snapshot` — OR the global assignment
   `_current_snapshot = ...` in `main()` must be updated to use the imported
   module reference. SAIL must update the `global _current_snapshot` write site
   in `main()` at the same time.

---

## Acceptance Criteria

1. `tools/agentic/sail_http_server.py` exists and contains the `HttpServer` class
2. `sail_supervisor.py` reduced to ≤ 870 lines
3. `python3 -c "from sail_http_server import HttpServer; print('OK')"` passes
   when run from `tools/agentic/`
4. `.venv-lint/bin/ruff check tools/agentic/` passes
5. `python3 -c "import sail_supervisor"` succeeds (no import errors, no circular
   import) when run from `tools/agentic/`
