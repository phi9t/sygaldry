# RFC-004: SAIL Supervisor Decomposition

**Status:** Draft — v4 (Phases 1-2 complete)
**Date:** 2026-03-21
**Priority:** Low

---

## 1. Problem

The shell-level cleanup work is now done: `_cfg_section` is shared via
`tools/agentic/lib/sail_config.sh`, and the attempt-registry writer is extracted
to `tools/agentic/record_attempt.py`. The remaining maintenance hotspot is
`tools/agentic/sail_supervisor.py`, which still mixes four concerns in one file.

`tools/agentic/sail_supervisor.py` combines:
- Temporal worker subprocess management
- Temporal connectivity probing
- Stall detection state machine
- Cron-style polling/scheduling

A bug in any one concern still requires understanding the full supervisor file.

---

## 2. Remaining Phase

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
