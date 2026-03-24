# RFC-076: Add Unit Tests for update_major_challenge_state.py

**Status:** Draft — v1
**Date:** 2026-03-24
**Priority:** Medium
**Effort:** S

---

## Problem

`tools/agentic/update_major_challenge_state.py` (162 lines) has no test file. It manages
the runtime state files that SAIL uses to track major challenge progress. Bugs in its
file I/O functions corrupt the challenge state machine:

- `load_state(path)` — reads JSON state with default handling for missing files
- `save_state(path, payload)` — writes state with `updatedAt` timestamp injection
- `read_slice_state(path, issue)` — merges stored state with issue defaults
- `append_history(path, record)` — appends a JSONL record to the history file
- `current_head(repo_dir)` — shells out to `git rev-parse HEAD`

There is no `tools/agentic/tests/test_update_major_challenge_state.py`.

---

## Solution

Create `tools/agentic/tests/test_update_major_challenge_state.py`:

```python
def test_load_state_returns_empty_dict_when_missing():
    # non-existent path → returns {}

def test_save_state_injects_updated_at():
    # save_state writes JSON with an "updatedAt" key

def test_save_state_roundtrip():
    # save then load → recovers original payload + updatedAt

def test_read_slice_state_applies_defaults():
    # missing state file + issue with sliceIndex=2 → default state

def test_read_slice_state_merges_stored():
    # saved state overrides defaults

def test_append_history_creates_file():
    # appending to non-existent path creates file with one JSONL line

def test_append_history_appends():
    # two appends → two JSONL lines in file
```

---

## Acceptance Criteria

1. `tools/agentic/tests/test_update_major_challenge_state.py` exists with ≥ 7 test functions.
2. `python3 -m pytest tools/agentic/tests/test_update_major_challenge_state.py -q` exits 0.
3. Tests use only `tmp_path` fixtures and synthetic data (no git repo, no real filesystem state).
