# RFC-052: Add Unit Tests for sail_status.py

**Status:** Draft — v1
**Date:** 2026-03-22
**Priority:** Medium
**Effort:** S

---

## Problem

`tools/agentic/sail_status.py` is 530 lines and has **zero tests**. It is the primary
operator-facing dashboard for SAIL. Its helper functions contain edge-case logic that
is currently unverifiable without running the full system:

- `age_str` (`sail_status.py:34`) — converts ISO timestamps to human-readable relative
  strings ("5s ago", "3m ago", "2h ago", "1d ago", "in the future"). Edge cases include
  future timestamps, `None` input, and malformed strings.
- `fmt_ts` (`sail_status.py:54`) — formats a timestamp for display. Same edge cases.
- `file_age_str` (`sail_status.py:64`) — reads mtime from a file path; returns "—" on
  OSError. Not tested.
- `_delta_str` (`sail_status.py:76`) — converts a timedelta to human-readable string.
  Not tested.
- `render_dashboard` (`sail_status.py`) — aggregates JSON from multiple files; silently
  returns empty data when files are absent. Not tested.

Compare: `tools/agentic/sail_supervisor.py` has a corresponding `test_sail_supervisor.py`
(visible in `tools/agentic/tests/`). `sail_status.py` has no equivalent.

`ls tools/agentic/tests/test_sail_status.py` returns "No such file or directory".

---

## Solution

Create `tools/agentic/tests/test_sail_status.py` with tests for the pure helper functions.
Avoid testing file I/O-heavy paths; instead test the deterministic formatting helpers
by injecting known timestamps.

Minimum coverage:

```python
import datetime as dt
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sail_status import age_str, fmt_ts, _delta_str


def test_age_str_seconds():
    ts = (dt.datetime.now(dt.UTC) - dt.timedelta(seconds=30)).isoformat()
    assert age_str(ts) == "30s ago"


def test_age_str_minutes():
    ts = (dt.datetime.now(dt.UTC) - dt.timedelta(minutes=5)).isoformat()
    assert age_str(ts) == "5m ago"


def test_age_str_hours():
    ts = (dt.datetime.now(dt.UTC) - dt.timedelta(hours=3)).isoformat()
    assert age_str(ts) == "3h ago"


def test_age_str_days():
    ts = (dt.datetime.now(dt.UTC) - dt.timedelta(days=2)).isoformat()
    assert age_str(ts) == "2d ago"


def test_age_str_none():
    assert age_str(None) == "unknown"


def test_age_str_malformed():
    result = age_str("not-a-timestamp")
    assert result == "not-a-timestamp" or result == "unknown"


def test_age_str_future():
    ts = (dt.datetime.now(dt.UTC) + dt.timedelta(seconds=60)).isoformat()
    assert age_str(ts) == "in the future"


def test_fmt_ts_none():
    assert fmt_ts(None) == "—"


def test_delta_str_sub_hour():
    delta = dt.timedelta(minutes=10)
    assert "10m" in _delta_str(delta)
```

---

## Acceptance Criteria

1. `ls tools/agentic/tests/test_sail_status.py` returns the file.
2. `pytest tools/agentic/tests/test_sail_status.py -q` exits 0 with at least 8 tests passing.
3. All tests cover the pure helper functions only (no subprocess calls, no file I/O mocking required).
