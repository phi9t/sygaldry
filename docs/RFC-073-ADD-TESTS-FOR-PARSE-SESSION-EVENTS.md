# RFC-073: Add Unit Tests for parse_session_events.py

**Status:** Draft — v1
**Date:** 2026-03-24
**Priority:** Medium
**Effort:** S

---

## Problem

`tools/agentic/parse_session_events.py` (217 lines) has no test file. It is responsible
for parsing Claude stream-json output from SAIL runs and extracting `SessionSummary`
data (token counts, tool usage, session duration). `metrics_updater.py` imports it
directly.

Core functions with no tests:

- `parse_events(path)` — reads a JSONL file, extracts token counts and tool call events
- `find_latest_events_file(log_dir)` — locates the most recent `*_structured.jsonl` file
- `update_current_task(task_file, session)` — merges session data into a task JSON file

Bugs here cause silent under-counting of API usage in SAIL metrics, which feeds the
SAIL cost dashboard.

There is no `tools/agentic/tests/test_parse_session_events.py`.

---

## Solution

Create `tools/agentic/tests/test_parse_session_events.py` with tests for all three
functions using synthetic JSONL fixtures:

```python
def test_parse_events_extracts_token_counts():
    # write a minimal structured JSONL with a usage block
    # assert SessionSummary.input_tokens and output_tokens are correct

def test_parse_events_empty_file():
    # empty JSONL file → SessionSummary with zero counts

def test_find_latest_events_file_returns_newest():
    # create 2 structured.jsonl files with different mtimes
    # assert find_latest_events_file returns the newer one

def test_find_latest_events_file_missing_dir():
    # non-existent directory → returns None

def test_update_current_task_merges_token_counts():
    # existing task.json + SessionSummary → merged file with updated counts
```

---

## Acceptance Criteria

1. `tools/agentic/tests/test_parse_session_events.py` exists with ≥ 5 test functions.
2. `python3 -m pytest tools/agentic/tests/test_parse_session_events.py -q` exits 0.
3. All tests use only standard library + tmp directories (no external services).
