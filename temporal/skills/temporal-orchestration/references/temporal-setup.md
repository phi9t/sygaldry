# Temporal orchestration reference (repo-scoped)

## Core entry points

- Worker: `cmd/worker`
- Pipeline runner (YAML): `cmd/orchestrate`
- Legacy JSON runner: `cmd/run`
- Pipeline workflow definition: `internal/workflows/pipeline.go`
- Activities: `internal/activities/`

## Start Temporal (local)

- Docker compose: `docker compose up -d`
- Script: `scripts/start-temporal.sh`

## Start a worker

- `go run ./cmd/worker`
- Or build then run: `go build -o /tmp/temporal-worker ./cmd/worker && /tmp/temporal-worker`

## Run a pipeline plan

- `go run ./cmd/orchestrate -plan examples/qwen_demo.yaml`
- `go run ./cmd/orchestrate -plan examples/e2e_test.yaml`
- Options:
  - `-workflow-id <id>`
  - `-task-queue <queue>`
  - `-log-dir <dir>`

## Example plans

- `examples/qwen_demo.yaml`
- `examples/e2e_test.yaml`
- `examples/pipeline.yaml`

## Logs and events

Default log dir is `./logs` unless overridden by `-log-dir` or `TEMPORAL_LOG_DIR`.

- Events: `logs/events.jsonl`
- Stdout: `logs/<workflowId>_<runId>_<stepId>_stdout.log`
- Stderr: `logs/<workflowId>_<runId>_<stepId>_stderr.log`
- Structured: `logs/<workflowId>_<runId>_<stepId>_structured.jsonl`

Control payload truncation via `TEMPORAL_LOG_MAX_BYTES`.

## CLI + UI helpers

- Logs CLI:
  - `./scripts/logs_cli.py list-runs`
  - `./scripts/logs_cli.py show-steps --workflow-id <id> --run-id <run>`
  - `./scripts/logs_cli.py follow --workflow-id <id> --run-id <run>`
- Structured log validation:
  - `./scripts/validate-structured-logs.sh /tmp/temporal-e2e-logs`
- JS visualizer:
  - `node visualizer/server.js`
  - Open `http://localhost:8787`

## Common environment variables

- `TEMPORAL_ADDRESS` (default: `localhost:7233`)
- `TEMPORAL_NAMESPACE` (default: `default`)
- `TEMPORAL_TASK_QUEUE` (default: `orchestration`)
- `TEMPORAL_LOG_DIR` (default: `./logs`)
- `TEMPORAL_LOG_MAX_BYTES` (default: `10000`)

## Validation

- End-to-end test: `scripts/test-e2e.sh`
