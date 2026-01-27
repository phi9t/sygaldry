# Temporal Orchestration

This directory contains the Temporal-based workflow engine used by Sygaldry.

Canonical docs:

- Quickstart examples: `examples/quickstart/QUICKSTART.md`
- Canonical design/current-state: `TEMPORAL_DESIGN.md`
- Onboarding guide: `TEMPORAL_ONBOARDING_GUIDE.md`

## What This Engine Provides

- Durable execution of YAML pipeline DAGs.
- Strict plan validation before submit.
- Retry, timeout, conditional execution, and failure-gating semantics.
- Structured run artifacts and low-friction inspection tools.

## Quick Start

From `temporal/`:

```bash
./scripts/run.sh examples/quickstart/01_hello.yaml
```

Manual mode:

```bash
# terminal 1
./scripts/start-temporal.sh

# terminal 2
go run ./cmd/worker

# terminal 3
go run ./cmd/orchestrate run -plan examples/quickstart/01_hello.yaml
```

## CLI Contract

```bash
go run ./cmd/orchestrate run -plan <plan.yaml> [-async] [-output yaml|json] [-set k=v ...]
go run ./cmd/orchestrate validate -plan <plan.yaml>
go run ./cmd/orchestrate status -workflow-id <id> [-run-id <id>] [-output yaml|json]
```

## Supported Step Types

- `command`
- `download`
- `docker_build`
- `docker_push`
- `package_build`
- `container_job`
- `hf_download_dataset`
- `hf_download_model`

## Plan Capabilities

- DAG dependencies via `depends_on`.
- Conditional execution via `when`.
- Failure control via `allow_failure`.
- Plan-level `params` and `env`.
- Template imports and template overrides.
- Output propagation with `::set-output name=<key>::<value>`.
- Interpolation:
  - `${{ params.<name> }}`
  - `${{ env.<name> }}`
  - `${{ steps.<id>.outputs.<name> }}`

## Logs and Artifacts

Default log root is `./logs` (or `$TEMPORAL_LOG_DIR`):

- `events.jsonl` (step lifecycle stream)
- `<workflow>_<run>_<step>_stdout.log`
- `<workflow>_<run>_<step>_stderr.log`
- `<workflow>_<run>_<step>_structured.jsonl`
- `<workflow>_<run>_plan.json`

Inspect via CLI:

```bash
./scripts/logs_cli.py list-runs
./scripts/logs_cli.py summary --latest
./scripts/logs_cli.py show-steps --latest
./scripts/logs_cli.py logs --latest
./scripts/logs_cli.py dag --latest
```

Visualizer:

```bash
node visualizer/server.js
# open http://localhost:8787
```

## Validation Ladder

```bash
go vet ./...
go test ./...
./scripts/test-e2e.sh
./scripts/e2e/run_medium.sh
./scripts/e2e/run_heavy.sh
```

## Requirements

- Go 1.23+
- Temporal CLI or Docker
- uv (for examples that use HuggingFace/model flows)
