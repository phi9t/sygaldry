# Temporal Orchestration (Local)

This repo provides a minimal Temporal setup that replaces Makefile-style orchestration with workflows and activities.

## Why Go SDK (vs Python or Rust)
- **Go** is an official Temporal SDK with first-class support, high performance, and a strong ergonomics/story for long-running workers.
- **Python** is also official but runs workflows in a sandboxed interpreter which can complicate some libraries and debugging.
- **Rust** does not have an official Temporal SDK today; community options exist but are not supported by Temporal.

## Quickstart (local dev server)

Option A: Temporal CLI dev server

```bash
./scripts/start-temporal.sh
```

This uses `temporal server start-dev` if the CLI is installed. The Temporal UI will be at `http://localhost:8233`.

Option B: Docker Compose

```bash
docker compose up
```

The Temporal UI will be at `http://localhost:8080`.

## Run the worker

```bash
TEMPORAL_ADDRESS=localhost:7233 \
TEMPORAL_NAMESPACE=default \
TEMPORAL_TASK_QUEUE=orchestration \
go run ./cmd/worker
```

## Execute a YAML plan

```bash
go run ./cmd/orchestrate -plan examples/pipeline.yaml
```

The output is a YAML summary of each step’s stdout/stderr, exit code, and state.
Stdout/stderr are truncated in the payload; full logs are written to files (see below).

## YAML plan format

Each step has an `id`, `type`, optional `depends_on`, and optional `when` condition.

Types:
- `command` → run any command
- `download` → download a URL to a local file (optional sha256 verification)
- `docker_build` → `docker build`
- `docker_push` → `docker push`
- `package_build` → run a packaging command

Conditional execution:
- If `when` is omitted, a step only runs if all dependencies succeed.
- If `when` is present, a step runs only when the referenced step has the specified status.
- To branch on failures, set `allow_failure: true` on the upstream step so the pipeline can continue.

Example plan (see `examples/pipeline.yaml`):

```yaml
steps:
  - id: download-data
    type: download
    download:
      url: https://example.com
      output: ./data/data.txt

  - id: build-image
    type: docker_build
    depends_on: [download-data]
    docker_build:
      image: my-org/my-image:dev
      context: .
    allow_failure: true

  - id: push-image
    type: docker_push
    depends_on: [build-image]
    when:
      step: build-image
      status: success
    docker_push:
      image: my-org/my-image:dev
```

## Demo: Qwen3 0.6B + FineWeb

This example installs uv, installs a Python runtime via uv, creates a uv venv, installs PyTorch + Transformers + Datasets, downloads the Qwen3 0.6B model, streams a few FineWeb samples, and runs inference.

```bash
# Start Temporal and worker in separate terminals
./scripts/start-temporal.sh

go run ./cmd/worker

# Run the demo plan
GOFLAGS="-mod=mod" go run ./cmd/orchestrate -plan examples/qwen_demo.yaml
```

Customize it via env vars in your shell before running:
- `QWEN_MODEL_ID` (default: `Qwen/Qwen3-0.6B-Base`)
- `FINEWEB_DATASET_ID` (default: `HuggingFaceFW/fineweb`)
- `FINEWEB_ITEMS` (default: `3`)
- `MAX_NEW_TOKENS` (default: `32`)

## Adding your own orchestration
- Edit `examples/pipeline.yaml` to represent your pipeline steps.
- For new step types, add activities in `internal/activities` and extend `internal/workflows/pipeline.go`.

## Logs and payload size
- Each activity result includes `stdout`/`stderr` **truncated** to `TEMPORAL_LOG_MAX_BYTES` (default: 10000 bytes).
- Full logs are written to files under `TEMPORAL_LOG_DIR` (default: `./logs`), and the result includes `stdoutPath`/`stderrPath`.
- Structured JSONL logs are written per step to `*_structured.jsonl`, and the result includes `structuredPath`.
- Step lifecycle events are appended to `logs/events.jsonl` (JSON Lines) for easy CLI/API querying.

## Inspect logs via CLI

```bash
./scripts/logs_cli.py list-runs
./scripts/logs_cli.py show-steps --workflow-id <id> --run-id <run>
./scripts/logs_cli.py follow --workflow-id <id> --run-id <run>
```

## Validate structured logs

```bash
./scripts/validate-structured-logs.sh /tmp/temporal-e2e-logs
```

## JS Visualizer

```bash
node visualizer/server.js
```

Then open `http://localhost:8787`.

## Requirements
- Go 1.23+ (Temporal Go SDK currently requires Go >= 1.23; go will auto-download the toolchain if needed).
- Temporal CLI **or** Docker.
- uv (for the Qwen demo).
