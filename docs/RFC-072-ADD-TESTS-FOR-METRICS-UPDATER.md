# RFC-072: Add Unit Tests for metrics_updater.py

**Status:** Draft — v1
**Date:** 2026-03-24
**Priority:** Medium
**Effort:** S

---

## Problem

`tools/agentic/metrics_updater.py` (238 lines) has no test file. It contains
business-critical aggregation logic that SAIL uses to compute run metrics:

- `load_attempts(runs_dir, cutoff)` — scans JSONL files and filters by timestamp
- `compute_metrics(attempts, runs_dir, cutoff, parse_fn)` — aggregates counts, durations,
  token usage across attempt records
- `count_runs(runs_dir, cutoff)` — counts completed run directories

Bugs in these functions cause silent metric corruption (wrong success rates, token
totals). The file imports `parse_session_events.py`, adding a transitive dep with no
coverage.

There is no `tools/agentic/tests/test_metrics_updater.py`.

---

## Solution

Create `tools/agentic/tests/test_metrics_updater.py` with tests for the three core
functions using temporary directories and synthetic JSONL fixtures:

```python
def test_load_attempts_filters_by_cutoff():
    # write two attempt records, one inside cutoff and one outside
    # assert only the in-window record is returned

def test_load_attempts_handles_missing_dir():
    # non-existent runs_dir → returns empty list

def test_compute_metrics_success_rate():
    # attempts with mixed statuses → correct success_rate

def test_compute_metrics_duration_aggregation():
    # attempts with known durations → correct avg_duration_sec

def test_count_runs_counts_matching_dirs():
    # synthetic run directory tree → correct count
```

---

## Acceptance Criteria

1. `tools/agentic/tests/test_metrics_updater.py` exists with ≥ 5 test functions.
2. `python3 -m pytest tools/agentic/tests/test_metrics_updater.py -q` exits 0.
3. All tests use only standard library + tmp directories (no external services).
