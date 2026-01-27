# Temporal Developer Onboarding Guide

**Last Updated:** 2026-02-12  
**Audience:** Engineers onboarding to this repository's Temporal subsystem  
**Canonical design reference:** `temporal/TEMPORAL_DESIGN.md`

## 1) What You Are Building Here

This repository uses Temporal to run multi-step YAML plans as durable workflows.

Execution path:

`plan.yaml` -> `cmd/orchestrate` -> `internal/workflows/pipeline.go` -> `cmd/worker` + `internal/activities/steps.go` -> logs/events/manifest -> CLI + visualizer

Primary boundaries:

- `cmd/orchestrate`: CLI contract (`run`, `validate`, `status`) and pre-submit validation.
- `internal/workflows/pipeline.go`: DAG scheduling, dependency gating, retry policy overrides, template/param/env/output expansion.
- `cmd/worker/main.go`: workflow/activity registration and worker process lifecycle.
- `internal/activities/steps.go`: step execution and artifact creation (`stdout`, `stderr`, `structured`, events).
- `scripts/logs_cli.py` and `visualizer/server.js`: run inspection APIs and UX.

## 2) Prerequisites

- Go 1.23+
- Temporal CLI or Docker
- Node.js (optional, only for local visualizer)

Expected defaults:

- Temporal address: `localhost:7233`
- Namespace: `default`
- Task queue: `orchestration`

## 3) 15-Minute First Success

From `temporal/`:

```bash
# terminal 1
./scripts/start-temporal.sh

# terminal 2
go run ./cmd/worker

# terminal 3
go run ./cmd/orchestrate run -plan examples/pipeline.yaml -output json
```

You should see:

- workflow/run IDs from `cmd/orchestrate`
- per-step outcomes in command output
- emitted artifacts in `./logs` (or `TEMPORAL_LOG_DIR`)

## 4) Observe a Run (CLI + UI)

### CLI inspection

```bash
./scripts/logs_cli.py list-runs
./scripts/logs_cli.py summary --latest
./scripts/logs_cli.py show-steps --latest
./scripts/logs_cli.py logs --latest
./scripts/logs_cli.py dag --latest
```

### Visualizer

```bash
node visualizer/server.js
```

Open `http://localhost:8787`.

## 5) Artifact Anatomy

Default root: `logs/`

- `events.jsonl`: workflow step lifecycle stream
- `<workflow>_<run>_<step>_stdout.log`: full stdout
- `<workflow>_<run>_<step>_stderr.log`: full stderr
- `<workflow>_<run>_<step>_structured.jsonl`: line-oriented structured stream logs
- `<workflow>_<run>_plan.json`: run manifest generated on submit

## 6) Code Reading Order (Do This in Sequence)

1. `temporal/cmd/orchestrate/main.go`
   - `runCommand`
   - `validateCommand`
   - `statusCommand`
   - `loadPipelinePlan`
   - `validatePlan`
   - `writePlanManifest`
2. `temporal/internal/workflows/pipeline.go`
   - `Pipeline`
   - `prepareStep`
   - `expandStepTemplates`
   - `activityOptionsForStep`
   - `startActivity`
3. `temporal/internal/activities/steps.go`
   - `RunCommand`
   - `DownloadFile`
   - `DockerBuild`
   - `ContainerJob`
   - `HFDownloadDataset`
   - `HFDownloadModel`
   - `setupLogWriters`
4. `temporal/cmd/worker/main.go`
   - workflow/activity registration and runtime wiring
5. `temporal/scripts/logs_cli.py` and `temporal/visualizer/server.js`
   - run summarization, event filtering, DAG reconstruction

## 7) Plan Authoring Rules

Top-level plan keys:

- `log_dir`
- `params`
- `env`
- `imports`
- `templates`
- `steps`

Supported step types:

- `command`
- `download`
- `docker_build`
- `docker_push`
- `package_build`
- `container_job`
- `hf_download_dataset`
- `hf_download_model`

Common behavior:

- `depends_on` controls DAG edges.
- `when` controls conditional execution.
- `allow_failure` allows downstream progress on failure.
- `retry` overrides per-step activity retry options.
- Output propagation uses step stdout markers:
  - `::set-output name=<key>::<value>`
- String interpolation supports:
  - `${{ params.<name> }}`
  - `${{ env.<name> }}`
  - `${{ steps.<id>.outputs.<name> }}`

Validate before submit:

```bash
go run ./cmd/orchestrate validate -plan <plan.yaml>
```

Schema reference: `temporal/schema/pipeline.schema.json`

## 8) Debugging Workflow

Use this order:

1. Confirm worker is running and connected to expected task queue.
2. Run `status` and `summary --latest` to identify failed step IDs.
3. Read `logs` output and matching `*_stderr.log`.
4. Inspect `events.jsonl` ordering for scheduling/condition surprises.
5. Use `dag --latest` or visualizer DAG view to verify dependencies.

Status command:

```bash
go run ./cmd/orchestrate status -workflow-id <workflow-id> -output json
```

## 9) Testing Ladder

From `temporal/`:

```bash
go vet ./...
go test ./...
./scripts/test-e2e.sh
./scripts/e2e/run_medium.sh
./scripts/e2e/run_heavy.sh
```

Purpose:

- unit/integration confidence in workflow/activity logic
- smoke confidence for CLI + worker + Temporal + logs
- medium/heavy confidence for retry/timing/monitoring semantics

## 10) How to Extend the System

Adding a new step type:

1. Add input/result handling and executor in `internal/activities/steps.go`.
2. Register the activity in `cmd/worker/main.go`.
3. Wire workflow dispatch in `internal/workflows/pipeline.go`.
4. Extend CLI validation in `cmd/orchestrate/main.go`.
5. Update `schema/pipeline.schema.json`.
6. Add example plan in `examples/`.
7. Add or update e2e coverage in `scripts/e2e/`.
8. Update `temporal/TEMPORAL_DESIGN.md` current state and future plan sections.

## 11) Production vs Local Assumptions

Current local-first assumptions:

- visualizer has no auth guard by default
- log retention cleanup is not fully implemented
- single local namespace/task queue conventions

Before production hardening, resolve the open items in `temporal/TEMPORAL_DESIGN.md` Priority B.

## 12) Recommended Week-1 Learning Path

Day 1:

- Run quickstart and inspect one successful run end-to-end.

Day 2:

- Modify an example plan using `params`, `env`, `templates`, `imports`.

Day 3:

- Read `pipeline.go` scheduling path and trace one run in logs/events.

Day 4:

- Extend one activity behavior and run smoke + medium e2e.

Day 5:

- Review retry/failure semantics and operational hardening gaps.

## 13) Upstream Temporal Learning References

Official docs and tutorials used to align this guide:

- Go SDK core application: https://docs.temporal.io/develop/go/core-application
- Go SDK client: https://docs.temporal.io/develop/go/temporal-client
- Go SDK testing suite: https://docs.temporal.io/develop/go/testing-suite
- Go SDK failure detection: https://docs.temporal.io/develop/go/failure-detection
- Temporal CLI workflow commands: https://docs.temporal.io/cli/workflow
- Worker deployments/versioning: https://docs.temporal.io/production-deployment/worker-deployments
- Learn Temporal Go first program: https://learn.temporal.io/getting_started/go/first_program_in_go/
- Learn Temporal Go hello world: https://learn.temporal.io/getting_started/go/hello_world_in_go/
- Upstream Go samples: https://github.com/temporalio/samples-go
- Go SDK source: https://github.com/temporalio/sdk-go

## 14) Guide Freshness and Maintenance

**Validated against local repo state on:** 2026-02-12  
**Upstream references checked on:** 2026-02-12

Update this guide when any of the following changes:

- CLI contract in `cmd/orchestrate`
- workflow or activity behavior
- supported plan schema/step types
- logging artifact format/paths
- e2e flow or expected developer workflow

When updated, also keep `temporal/TEMPORAL_DESIGN.md` synchronized.
