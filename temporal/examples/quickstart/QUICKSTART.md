# Temporal Quick-Start Examples

Get productive with the Temporal orchestration infra in 5 minutes.

These examples are self-contained YAML pipeline plans, ordered by complexity. Examples 01-05 use only `command` steps and run on any machine with Go and Temporal. Example 06 requires the full Sygaldry GPU container stack.

## Prerequisites

- Go 1.23+
- Temporal CLI (`temporal`) or Docker (for Temporal server)
- All commands run from `temporal/` directory

## One-Command Run

The fastest path -- `scripts/run.sh` starts Temporal, starts a worker, runs your plan, and prints a summary:

```bash
cd temporal
./scripts/run.sh examples/quickstart/01_hello.yaml
```

## Manual Three-Terminal Setup

For more control or when debugging:

```bash
# Terminal 1: Start Temporal server
./scripts/start-temporal.sh

# Terminal 2: Start the worker
go run ./cmd/worker

# Terminal 3: Run a plan
go run ./cmd/orchestrate run -plan examples/quickstart/01_hello.yaml
```

## Validate Before Running

Check a plan for errors (missing fields, bad deps, cycles) without executing it:

```bash
go run ./cmd/orchestrate validate -plan examples/quickstart/03_outputs.yaml
```

## Inspect Results

After a run completes, use `logs_cli.py` to inspect artifacts:

```bash
# List all runs
./scripts/logs_cli.py list-runs

# Summary of latest run
./scripts/logs_cli.py summary --latest

# Show step-by-step results
./scripts/logs_cli.py show-steps --latest

# Full stdout/stderr logs
./scripts/logs_cli.py logs --latest

# DAG structure
./scripts/logs_cli.py dag --latest
```

## Machine-Readable Output (for Agents)

Use `-output json` to get structured results suitable for parsing:

```bash
# Synchronous run with JSON output
go run ./cmd/orchestrate run -plan examples/quickstart/01_hello.yaml -output json

# Async launch (returns workflow/run IDs immediately)
go run ./cmd/orchestrate run -plan examples/quickstart/02_chain.yaml -async -output json

# Check status by workflow ID
go run ./cmd/orchestrate status -workflow-id <id> -output json
```

## Override Parameters at Runtime

Use `-set key=value` to override `params` without editing the YAML:

```bash
go run ./cmd/orchestrate run \
  -plan examples/quickstart/03_outputs.yaml \
  -set greeting="Bonjour" \
  -set subject="le monde"
```

## Example Progression

| File | Concept | New Features |
|------|---------|-------------|
| `01_hello.yaml` | Minimal plan | Single step, `command` type |
| `02_chain.yaml` | Sequential deps | `depends_on`, multi-step DAG |
| `03_outputs.yaml` | Data passing | `params`, `::set-output`, `${{ }}` interpolation |
| `04_branching.yaml` | Conditional logic | `allow_failure`, `when` clauses, diamond DAG |
| `05_templates.yaml` | Reusable patterns | `imports`, `templates`, template overrides |
| `06_gpu_experiment.yaml` | Full ML pipeline | `container_job`, `hf_download_model` (requires GPU) |

## Common Errors

**"unable to create Temporal client"** -- Temporal server is not running. Start it with `./scripts/start-temporal.sh` or `docker compose up`.

**"no worker is polling task queue"** -- The worker is not running. Start it with `go run ./cmd/worker`.

**"unknown field" in YAML** -- Strict decoding is enabled. Check field names against the schema at `schema/pipeline.schema.json`.

**"dependency ... not found"** -- A `depends_on` references a step ID that does not exist. Step IDs are case-sensitive.

**"cycle detected"** -- Your dependency graph has a loop. Use `go run ./cmd/orchestrate validate -plan <file>` to see which steps are involved.

## Artifacts

After a run, artifacts are written to `logs/` (or `$TEMPORAL_LOG_DIR`):

```
logs/
  events.jsonl                              # Step lifecycle events (started/completed/failed)
  <workflow>_<run>_<step>_stdout.log        # Per-step stdout
  <workflow>_<run>_<step>_stderr.log        # Per-step stderr
  <workflow>_<run>_<step>_structured.jsonl   # Per-step structured log stream
  <workflow>_<run>_plan.json                # Plan manifest (snapshot of what was submitted)
```
