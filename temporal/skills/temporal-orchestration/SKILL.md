---
name: temporal-orchestration
description: Use when working in this repo to run or extend the Temporal-based orchestration system for multi-step jobs (YAML pipeline plans, demo runs, logging, UI/CLI inspection, or adding new step types). Trigger for tasks like running a pipeline, adding a new workflow step, debugging execution, or inspecting logs/events for runs.
---

# Temporal Orchestration

## Overview

Use the repo's Temporal pipeline workflow to execute multi-step jobs (downloads, builds, packaging, model demos) and inspect results via logs, events, and the visualizer.

## Quick start (run a plan)

1. Start Temporal (Docker or script).
2. Start a worker (Go).
3. Run a pipeline YAML with `cmd/orchestrate`.

## Core entry points

- Worker: `cmd/worker`
- Pipeline runner (YAML): `cmd/orchestrate`
- Legacy JSON runner: `cmd/run`
- Pipeline workflow definition: `internal/workflows/pipeline.go`
- Activities: `internal/activities/`

## Start Temporal (local)

```bash
# Docker compose
docker compose up -d

# Or use the repo script
scripts/start-temporal.sh
```

Temporal UI: `http://localhost:8080` (Docker) or `http://localhost:8233` (script/CLI dev server).

## Start a worker

```bash
go run ./cmd/worker

# Or build then run
go build -o /tmp/temporal-worker ./cmd/worker && /tmp/temporal-worker
```

## Run a pipeline plan

```bash
go run ./cmd/orchestrate -plan examples/qwen_demo.yaml
go run ./cmd/orchestrate -plan examples/e2e_test.yaml
go run ./cmd/orchestrate -plan examples/pipeline.yaml
```

Options:

| Flag | Purpose |
|------|---------|
| `-workflow-id <id>` | Override auto-generated workflow ID |
| `-task-queue <queue>` | Override task queue (default: `orchestration`) |
| `-log-dir <dir>` | Override log directory (default: `./logs`) |

## Typical tasks

### Run an existing plan

- Run a demo (Qwen) or e2e plan using the scripts in `scripts/`.
- Override log directory and task queue via flags or env.

### Create or edit a pipeline

- Modify a YAML plan in `examples/`.
- Ensure each step has a unique `id`, `type`, and correct dependencies.
- Keep steps small and deterministic; prefer `command` steps unless a specialized activity exists.

### Observe progress and outputs

- Use the CLI to list runs, show steps, or follow events.
- Inspect stdout/stderr and structured JSONL logs per step.
- Use the JS visualizer for live updates.

### Add a new step type

- Add activity code under `internal/activities/`.
- Wire it into the pipeline workflow in `internal/workflows/pipeline.go`.
- Update examples and validate with `scripts/test-e2e.sh`.

## Logs and artifacts

Default log dir is `./logs` unless overridden by `-log-dir` or `TEMPORAL_LOG_DIR`.

| Path | Contents |
|------|---------|
| `logs/events.jsonl` | Structured workflow events |
| `logs/<workflowId>_<runId>_<stepId>_stdout.log` | Step stdout |
| `logs/<workflowId>_<runId>_<stepId>_stderr.log` | Step stderr |
| `logs/<workflowId>_<runId>_<stepId>_structured.jsonl` | Structured step log |

Control payload truncation via `TEMPORAL_LOG_MAX_BYTES`.

## CLI + UI helpers

```bash
# Logs CLI
./scripts/logs_cli.py list-runs
./scripts/logs_cli.py show-steps --workflow-id <id> --run-id <run>
./scripts/logs_cli.py follow --workflow-id <id> --run-id <run>

# Structured log validation
./scripts/validate-structured-logs.sh /tmp/temporal-e2e-logs

# JS visualizer
node visualizer/server.js
# Open http://localhost:8787
```

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `TEMPORAL_ADDRESS` | `localhost:7233` | Temporal server address |
| `TEMPORAL_NAMESPACE` | `default` | Namespace |
| `TEMPORAL_TASK_QUEUE` | `orchestration` | Task queue name |
| `TEMPORAL_LOG_DIR` | `./logs` | Log output directory |
| `TEMPORAL_LOG_MAX_BYTES` | `10000` | Max bytes for stdout/stderr in payloads |

## Validation

```bash
# End-to-end test
scripts/test-e2e.sh

# Go unit tests (89 test cases)
cd temporal && go test ./...
```
