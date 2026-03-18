# RFC-004: SAIL Infrastructure Simplification

**Status:** Draft — v3 (10-pass revision)
**Date:** 2026-03-16
**Priority:** Low — lower priority than RFC-002 and RFC-003

---

## 1. Problem

Three concrete maintenance issues in `tools/agentic/`.

### 1.1 Duplicated `_cfg_section` YAML parser

`tools/agentic/run_improvement_loop.sh:71-83` and `tools/agentic/sail_cron.sh` both contain a verbatim copy of this AWK-based YAML section extractor. Any bug fix must be applied twice.

Exact definition (same in both files):
```bash
_cfg_section() {
    local section="$1" key="$2" default="$3"
    local value
    value="$(
        awk -v target_section="${section}" -v target_key="${key}" '
            $0 ~ ("^" target_section ":") { in_section = 1; next }
            in_section && $0 ~ /^[^[:space:]]/ { in_section = 0 }
            in_section && $0 ~ ("^  " target_key ":") {
                sub(/^[^:]+:[[:space:]]*/, "", $0)
                sub(/[[:space:]]+#.*$/, "", $0)
                print; exit
            }
        ' "${CONFIG}"
    )"
    echo "${value:-${default}}"
}
```

### 1.2 Embedded Python block in shell script

`run_improvement_loop.sh` contains a heredoc Python block for writing to `.agentic/attempted.jsonl`. This block cannot be linted with `ruff`, tested in isolation, or type-checked. It runs via `python3 -c "$(cat <<'PYEOF' ... PYEOF)"`.

### 1.3 `sail_supervisor.py` mixes four concerns (786 LOC)

`tools/agentic/sail_supervisor.py` combines:
- Temporal worker subprocess management
- Temporal connectivity probing
- Stall detection state machine
- Cron-style polling/scheduling

A bug in any one concern requires understanding all 786 lines.

---

## 2. Phases

### Phase 1 — Extract `_cfg_section` to shared lib

**New file:** `tools/agentic/lib/sail_config.sh`

```bash
#!/usr/bin/env bash
# Shared SAIL config helpers. Source this; do not execute directly.

# Usage: _cfg_section <section> <key> <default>
# Reads a 2-level YAML key from ${CONFIG} (must be set by caller).
_cfg_section() {
    local section="$1" key="$2" default="$3"
    local value
    value="$(
        awk -v target_section="${section}" -v target_key="${key}" '
            $0 ~ ("^" target_section ":") { in_section = 1; next }
            in_section && $0 ~ /^[^[:space:]]/ { in_section = 0 }
            in_section && $0 ~ ("^  " target_key ":") {
                sub(/^[^:]+:[[:space:]]*/, "", $0)
                sub(/[[:space:]]+#.*$/, "", $0)
                print; exit
            }
        ' "${CONFIG}"
    )"
    echo "${value:-${default}}"
}
```

**Update `run_improvement_loop.sh`:** Add after `readonly CONFIG`:
```bash
# shellcheck source=tools/agentic/lib/sail_config.sh
source "${SCRIPT_DIR}/lib/sail_config.sh"
```
Delete the inline `_cfg_section` definition (lines 71-83).

**Update `sail_cron.sh`:** Same change.

**Verify:** `shellcheck -s bash -S warning tools/agentic/run_improvement_loop.sh tools/agentic/sail_cron.sh tools/agentic/lib/sail_config.sh`

---

### Phase 2 — Extract embedded Python

Find the heredoc Python block in `run_improvement_loop.sh` and move it to `tools/agentic/record_attempt.py`:

```python
#!/usr/bin/env python3
"""Record an attempt entry to .agentic/attempted.jsonl.

Usage: record_attempt.py <issue_id> <status> [--state-dir .agentic]
"""
import argparse
import datetime
import json
import pathlib
import sys


def record(issue_id: str, status: str, state_dir: pathlib.Path) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    entry = {
        "issue_id": issue_id,
        "status": status,
        "ts": datetime.datetime.utcnow().isoformat() + "Z",
    }
    with open(state_dir / "attempted.jsonl", "a") as f:
        json.dump(entry, f)
        f.write("\n")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("issue_id")
    p.add_argument("status")
    p.add_argument("--state-dir", default=".agentic", type=pathlib.Path)
    args = p.parse_args()
    record(args.issue_id, args.status, args.state_dir)
```

Replace the heredoc Python in `run_improvement_loop.sh` with:
```bash
python3 "${SCRIPT_DIR}/record_attempt.py" "$issue_id" "$status" \
    --state-dir "${ATTEMPTED_DIR:-${REPO_DIR}/.agentic}"
```

**Verify:**
```bash
# Ruff/black clean
.venv-lint/bin/ruff check tools/agentic/record_attempt.py
.venv-lint/bin/black --check tools/agentic/record_attempt.py

# Smoke test
python3 tools/agentic/record_attempt.py test-issue-1 attempted --state-dir /tmp/test-sail
cat /tmp/test-sail/attempted.jsonl
# {"issue_id": "test-issue-1", "status": "attempted", "ts": "..."}
```

---

### Phase 3 — Decompose `sail_supervisor.py`

Split `sail_supervisor.py` (786 LOC) along four natural boundaries:

**`tools/agentic/worker_manager.py`** (~150 LOC) — worker subprocess:
```python
class WorkerManager:
    """Start, stop, restart, and health-check the Temporal worker subprocess."""

    def __init__(self, temporal_dir: str, log_file: str): ...

    def start(self) -> subprocess.Popen: ...
    def stop(self, timeout: float = 10.0) -> None: ...
    def restart(self) -> subprocess.Popen: ...
    def is_alive(self) -> bool: ...
```

**`tools/agentic/temporal_probe.py`** (~100 LOC) — connectivity check:
```python
class TemporalProbe:
    """Check whether the Temporal server is reachable."""

    def __init__(self, address: str, namespace: str): ...
    def is_reachable(self, timeout: float = 5.0) -> bool: ...
    def wait_until_ready(self, max_wait: float = 60.0) -> bool: ...
```

**`tools/agentic/sail_supervisor.py`** (reduced to ~200 LOC) — state machine:
```python
from worker_manager import WorkerManager
from temporal_probe import TemporalProbe

class SailSupervisor:
    """State machine: IDLE → RUNNING → STALLED → HEALING → IDLE."""

    def __init__(self, config: dict): ...
    def run(self) -> None: ...
    def _check_health(self) -> HealthStatus: ...
    def _heal(self) -> None: ...
```

The decomposition preserves observable behavior. The `sail_supervisor.py` entry point (`if __name__ == "__main__":`) and CLI flags remain identical.

**Verify:**
```bash
python3 -c "import sys; sys.path.insert(0, 'tools/agentic'); import sail_supervisor"
sygaldry sail supervisor --help   # same output as before
```

---

## 3. Files Changed

| File | Action |
|------|--------|
| `tools/agentic/lib/sail_config.sh` | New |
| `tools/agentic/run_improvement_loop.sh` | Remove inline `_cfg_section`, remove embedded Python |
| `tools/agentic/sail_cron.sh` | Remove inline `_cfg_section` |
| `tools/agentic/record_attempt.py` | New |
| `tools/agentic/sail_supervisor.py` | Decomposed to ~200 lines |
| `tools/agentic/worker_manager.py` | New |
| `tools/agentic/temporal_probe.py` | New |

---

## 4. Verification

```bash
# Shell linting
shellcheck -s bash -S warning \
    tools/agentic/run_improvement_loop.sh \
    tools/agentic/sail_cron.sh \
    tools/agentic/lib/sail_config.sh

# Python linting
.venv-lint/bin/ruff check tools/agentic/
.venv-lint/bin/black --check tools/agentic/

# End-to-end
sygaldry sail discover              # issues list unchanged
sygaldry sail supervisor --help     # supervisor CLI unchanged

# Pytest
cd tools/agentic && python3 -m pytest tests/ -q
```

---

## 5. Implementation Order

Phases are independent. Recommended order: 1 → 2 → 3.
Phase 3 is the highest risk; it can be deferred if 1+2 deliver enough value.

## 6. Risk Register

| Risk | Severity | Mitigation |
|------|----------|-----------|
| Shell sourcing breaks on dash | Low | Both consumers require bash; header enforces it |
| `record_attempt.py` interface differs from heredoc | Low | Match exact args and output format; smoke test |
| Phase 3 import path issues | Medium | `python3 -c "import sail_supervisor"` in CI |
| Phase 3 state machine behavior changes | Medium | Existing `test_sail_supervisor.py` covers state transitions |
