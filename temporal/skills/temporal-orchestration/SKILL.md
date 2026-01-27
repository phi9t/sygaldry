---
name: temporal-orchestration
description: Use when working in this repo to run or extend the Temporal-based orchestration system for multi-step jobs (YAML pipeline plans, demo runs, logging, UI/CLI inspection, or adding new step types). Trigger for tasks like running a pipeline, adding a new workflow step, debugging execution, or inspecting logs/events for runs.
---

# Temporal Orchestration

## Overview

Use the repo’s Temporal pipeline workflow to execute multi-step jobs (downloads, builds, packaging, model demos) and inspect results via logs, events, and the visualizer.

## Quick start (run a plan)

1) Start Temporal (Docker): use the repo script or compose.
2) Start a worker (Go).
3) Run a pipeline YAML with `cmd/orchestrate`.

Use the reference file for the exact commands and paths.

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

## References

Read `references/temporal-setup.md` for concrete commands, env vars, file paths, and logging conventions.
