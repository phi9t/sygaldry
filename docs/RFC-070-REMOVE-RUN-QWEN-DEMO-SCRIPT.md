# RFC-070: Remove run-qwen-demo.sh Demo Script

**Status:** Draft — v1
**Date:** 2026-03-24
**Priority:** Low
**Effort:** XS

---

## Problem

`temporal/scripts/run-qwen-demo.sh` (76 lines) is a convenience wrapper that:

1. Starts Temporal via `docker compose up -d`
2. Waits for the server to be ready
3. Registers search attributes via `register_search_attributes.sh`
4. Starts a worker in the background
5. Runs `go run ./cmd/orchestrate run -plan examples/qwen_demo.yaml`
6. Tails logs

This script is not referenced from `validate_all.sh`, `CLAUDE.md`, any CI pipeline,
or any other script. The underlying pipeline it drives (`examples/qwen_demo.yaml`) is
well-maintained and can be executed directly via the generic `cmd/orchestrate` CLI with
the standard setup steps documented in `CLAUDE.md`.

Keeping a standalone demo runner script that embeds cluster-startup logic creates a
secondary, divergence-prone code path for Temporal setup. When `start-temporal.sh` or
the worker startup changes, `run-qwen-demo.sh` becomes quietly stale.

---

## Solution

Delete the script:

```
temporal/scripts/run-qwen-demo.sh
```

Users who want to run the Qwen demo follow the standard workflow documented in CLAUDE.md:

```bash
# Terminal 1: Start Temporal
cd temporal && ./scripts/start-temporal.sh

# Terminal 2: Start worker
TEMPORAL_ADDRESS=localhost:7233 go run ./cmd/worker

# Terminal 3: Run the pipeline
go run ./cmd/orchestrate run -plan examples/qwen_demo.yaml
```

---

## Acceptance Criteria

1. `temporal/scripts/run-qwen-demo.sh` does not exist.
2. `grep -rn "run-qwen-demo" . --include="*.sh" --include="*.md" --include="*.yaml"` returns 0 matches (excluding `docs/RFC-*.md`).
