# Temporal Orchestration Design (Canonical)

**Last Updated:** 2026-02-12  
**Status:** Active source of truth

This document is the single canonical design/planning reference for the Temporal subsystem in this repository.

Canonical developer onboarding/learning guide:
- `temporal/TEMPORAL_ONBOARDING_GUIDE.md`

It consolidated prior split design content from:
- historical roadmap notes formerly in `temporal/TEMPORAL_UX_ROADMAP.md` (now removed)
- Temporal design/planning notes embedded in `temporal/README.md`

## Goals

1. Make workflow authoring easy for humans and coding agents.
2. Keep execution/monitoring reproducible and automatable via CLI.
3. Maintain a clear, current snapshot of implemented behavior and next work.

## Current State (Accurate as of 2026-02-12)

### Architecture

YAML plan -> `cmd/orchestrate` -> Temporal workflow (`internal/workflows/pipeline.go`) -> worker activities (`internal/activities/steps.go`) -> log/event artifacts -> CLI/web observability.

Primary runtime components:
- `cmd/orchestrate`: submit/validate/status interface.
- `cmd/worker`: registers workflows + activities.
- `internal/workflows/pipeline.go`: DAG scheduler and orchestration logic.
- `internal/activities/steps.go`: execution layer for supported step types.
- `scripts/logs_cli.py`: log/event inspection.
- `visualizer/server.js` + `visualizer/index.html`: browser UI.

### Implemented UX/Engine Capabilities

#### CLI
- Subcommands: `run`, `validate`, `status`.
- Backward compatibility: `go run ./cmd/orchestrate -plan ...` still maps to run mode.
- Output formats: `-output yaml|json`.
- Async launch: `-async` returns workflow/run IDs immediately.
- Parameter overrides: repeatable `-set key=value`.
- Strict YAML decoding (`KnownFields(true)`).
- Pre-submit validation includes:
  - required fields by step type
  - dependency existence
  - `when` validation
  - cycle detection

#### Pipeline Composition
- Top-level plan support: `params`, `env`, `templates`, `imports`, `steps`.
- Inline/external template resolution with step-level overrides.
- Runtime variable expansion in string fields:
  - `${{ params.<name> }}`
  - `${{ env.<name> }}`
  - `${{ steps.<id>.outputs.<name> }}`
- Step output capture from stdout convention:
  - `::set-output name=<key>::<value>`

#### Scheduling/Execution
- Streaming DAG scheduling (schedule-on-complete) via Temporal selector.
- Per-step retry overrides (`retry` block) applied to activity options.
- Env precedence fixed so explicit step env overrides inherited process env.

#### Monitoring and Artifacts
- `logs_cli.py` supports:
  - `list-runs`
  - `summary --latest`
  - `show-steps --latest`
  - `logs --latest`
  - `dag --latest`
  - `tail` / `follow`
- Run manifest artifact emitted on submit:
  - `<log_dir>/<workflow>_<run>_plan.json`
- Visualizer APIs:
  - `/api/runs`
  - `/api/runs/:id`
  - `/api/dag?runId=...`
  - `/api/events`

#### Developer UX
- One-command launcher: `scripts/run.sh <plan.yaml>`.
- Developer onboarding guide: `temporal/TEMPORAL_ONBOARDING_GUIDE.md`.
- JSON Schema for plans: `schema/pipeline.schema.json`.
- E2E harness and suites:
  - `scripts/e2e/lib.sh`
  - `scripts/e2e/run_smoke.sh`
  - `scripts/e2e/run_medium.sh`
  - `scripts/e2e/run_heavy.sh`
  - `scripts/e2e/run_all.sh`
- Cookbook examples:
  - `examples/ci-pipeline.yaml`
  - `examples/ml-training.yaml`
  - `examples/doc-processing.yaml`
  - `examples/templates/*.yaml`
  - `examples/e2e/*.yaml`

## Interfaces

### CLI Contract

#### Run
```bash
go run ./cmd/orchestrate run -plan <plan.yaml> [-async] [-output yaml|json] [-set k=v ...]
```

#### Validate
```bash
go run ./cmd/orchestrate validate -plan <plan.yaml>
```

#### Status
```bash
go run ./cmd/orchestrate status -workflow-id <id> [-run-id <id>] [-output yaml|json]
```

### Plan Schema Highlights

Top-level keys:
- `log_dir`
- `params`
- `env`
- `imports`
- `templates`
- `steps`

Step features:
- types: `command`, `download`, `docker_build`, `docker_push`, `package_build`, `container_job`, `hf_download_dataset`, `hf_download_model`
- `depends_on`, `when`, `allow_failure`, `timeout_seconds`, `retry`, `template`

## Known Gaps / Residual Risks

1. Worker entrypoint still has minimal direct test coverage.
2. Visualizer has no authentication (local/dev only assumption).
3. Log retention/cleanup policy is not yet implemented.

## Future Plan

### Priority A: E2E Expansion (Implemented)

#### E2E-01: CLI async lifecycle
- Implemented in `scripts/e2e/e2e_01_cli_async.sh`.

#### E2E-02: Params + outputs + substitution
- Implemented in `scripts/e2e/e2e_02_params_outputs.sh`.

#### E2E-03: Template import/merge semantics
- Implemented in `scripts/e2e/e2e_03_templates_imports.sh`.

#### E2E-04: Validation guardrails
- Implemented in `scripts/e2e/e2e_04_validation_guardrails.sh`.

#### E2E-05: Retry and failure semantics
- Implemented in `scripts/e2e/e2e_05_retry_failure_semantics.sh`.

#### E2E-06: Streaming DAG semantics
- Implemented in `scripts/e2e/e2e_06_streaming_dag.sh`.

#### E2E-07: Monitoring/DAG consistency
- Implemented in `scripts/e2e/e2e_07_monitoring_consistency.sh`.

### Priority B: Operational Hardening

1. Add worker-focused tests.
2. Add optional local visualizer auth guard.
3. Add log retention policy/tooling (age- or size-based pruning).

#### Priority B acceptance criteria

1. Worker-focused tests:
   - `cmd/worker/main.go` has direct tests covering env resolution and workflow/activity registration expectations.
   - `go test ./...` continues to pass with worker test coverage included.
2. Visualizer auth guard:
   - unauthenticated requests to `/api/runs`, `/api/runs/:id`, `/api/dag`, and `/api/events` are denied when auth is enabled.
   - authenticated requests succeed with unchanged payload schemas.
3. Log retention:
   - deterministic cleanup command removes files older than configured TTL and optionally enforces size cap.
   - cleanup is safe (only within configured log root) and test-covered for both retention modes.

### CI Staging Strategy

1. PR smoke: `scripts/test-e2e.sh` (wrapper to `scripts/e2e/run_smoke.sh`).
2. Nightly medium: `scripts/e2e/run_medium.sh`.
3. Nightly heavy: `scripts/e2e/run_heavy.sh`.
4. Release gate: full matrix + cookbook runs.

## Phase Status Snapshot

| Phase | Scope | Status |
|------|-------|--------|
| Phase 1 | Quick Wins (run.sh, latest logs, async/json, validate/status) | Implemented |
| Phase 2 | Outputs + substitution + params/env | Implemented |
| Phase 3 | Templates/imports + examples | Implemented |
| Phase 4 | Monitoring improvements (CLI + DAG visualizer) | Implemented |
| Phase 5 | Schema + cycle validation | Implemented |
| Phase 6 | Retry/env fix/streaming scheduler | Implemented |

## Maintenance Rule

When Temporal behavior changes (code, APIs, examples, tests, operational flow), update this document in the same change so it stays accurate for:
- **Current state** (what exists now)
- **Future plan** (what remains and priority/order)

## Design Review (2026-02-12)

### Findings (Ordered by Severity)

1. Medium: metadata inconsistency was present.
   - The document header showed `Last Updated: 2026-02-12`, while state text claimed “Accurate as of 2026-02-11”.
   - Evidence: `temporal/TEMPORAL_DESIGN.md`.
   - Resolution applied: aligned “Current State” date to 2026-02-12.
2. Medium: canonical doc referenced a removed design file without context.
   - `temporal/TEMPORAL_UX_ROADMAP.md` was removed from repo, but design intro still presented it as an active source path.
   - Evidence: `temporal/TEMPORAL_DESIGN.md`, repository file list in `temporal/`.
   - Resolution applied: reworded as historical consolidated source (removed file).
3. Medium: Priority B lacked measurable completion criteria.
   - Future items were directional only (tests/auth/retention) without explicit “done” conditions.
   - Evidence: `temporal/TEMPORAL_DESIGN.md`.
   - Resolution applied: added `Priority B acceptance criteria` with objective checks.
4. Low: Known gaps list is accurate but should stay synchronized with test reality.
   - Worker test gap remains valid; no direct worker test file currently exists.
   - Evidence: `temporal/cmd/worker/main.go`, no `temporal/cmd/worker/*_test.go`.

### Open Questions / Assumptions

1. Assumption: visualizer auth remains optional and disabled by default for local workflows.
2. Assumption: retention tooling will be script-driven (manual/cron) instead of on-read or on-write pruning.
3. Open question: whether Priority B should be split into separate PRs (worker tests, auth, retention) or delivered as one batch.

### Recommended Doc Corrections

1. Keep `Last Updated` and “Accurate as of” synchronized in every change.
2. Avoid listing removed files as live references; mark them explicitly as historical if needed.
3. For each future-plan item, include acceptance criteria and validation command(s).

### Follow-up Actions

1. Implement Priority B worker-focused tests for `cmd/worker`.
2. Implement optional auth guard for visualizer API endpoints.
3. Implement retention command and add tests/documented usage.
4. Update this section after Priority B execution to record closure status.

### Reviewed-Against

1. `temporal/cmd/orchestrate/main.go`
2. `temporal/cmd/worker/main.go`
3. `temporal/internal/workflows/pipeline.go`
4. `temporal/scripts/e2e/lib.sh`
5. `temporal/scripts/e2e/e2e_01_cli_async.sh`
6. `temporal/scripts/e2e/e2e_07_monitoring_consistency.sh`
7. `temporal/visualizer/server.js`
8. `temporal/README.md`
