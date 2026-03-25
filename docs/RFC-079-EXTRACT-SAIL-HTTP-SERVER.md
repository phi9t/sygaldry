# RFC-079: Extract HttpServer Class from sail_supervisor.py

**Status:** Open
**Date:** 2026-03-25
**Priority:** Medium
**Effort:** S

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
(including its `_handler` inner class and all methods) into it.

In `sail_supervisor.py`, replace the class definition with:
```python
from sail_http_server import HttpServer
```

---

## Acceptance Criteria

1. `tools/agentic/sail_http_server.py` exists and contains the `HttpServer` class
2. `sail_supervisor.py` reduced to ≤ 870 lines
3. `python3 -c "from sail_http_server import HttpServer; print('OK')"` passes
   when run from `tools/agentic/`
4. `.venv-lint/bin/ruff check tools/agentic/` passes
