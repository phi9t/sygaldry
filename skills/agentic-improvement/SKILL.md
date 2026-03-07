# Skill: agentic-improvement

Runs the **Sygaldry Agentic Improvement Loop (SAIL)** — a continuous improvement
pipeline that discovers code issues, plans fixes with a high-capability LLM,
implements them with a cost-effective LLM, validates, and opens PRs automatically.

## Architecture

```
sygaldry sail  (bin/sygaldry → run_improvement_loop.sh)
  ├─ preflight: nc -z $TEMPORAL_HOST $TEMPORAL_PORT
  ├─ discover_issues.py        → JSON array of issues (7 sources)
  └─ for each issue (up to max_tasks_per_run, optionally parallel):
       dedup check (.agentic/attempted.jsonl + remote branch check)
       for attempt in 0..max_retries:
         go run ./cmd/orchestrate → improvement_loop.yaml (8 steps):
           1. plan        (agent_task: planner_engine/model, writes plan to /tmp/)
           2. branch      (git_op: branch)
           3. implement   (agent_task: implementer_engine/model, reads plan file)
           4. validate    (command: ./validate_all.sh --quick)
           5a. commit_pr  (git_op: commit)      ← on validate success
           5b. push_branch (git_op: push)        ← on validate success
           5c. create_pr  (git_op: create-pr)   ← on validate success
           5d. rollback   (git_op: reset+patch) ← on validate failure
         on failure: capture validate stderr → retry with failure context
       record result in .agentic/attempted.jsonl
```

## Quick Start

```bash
# 1. Start the Temporal server (one terminal — keep running)
cd temporal && ./scripts/start-temporal.sh

# 2. Start the Temporal worker (another terminal)
sygaldry sail worker

# 3. Preview discovered issues (no Temporal needed)
sygaldry sail discover

# 4. Dry run: log what would happen, no LLM calls
sygaldry sail --dry-run

# 5. Echo engine: exercises full pipeline without LLM tokens
SAIL_PLANNER_ENGINE=echo SAIL_IMPLEMENTER_ENGINE=echo sygaldry sail

# 6. Real cycle (requires Temporal worker + gh CLI + claude CLI)
sygaldry sail

# Validate the YAML plan schema
sygaldry sail validate-plan
```

Or with `just`:
```bash
just sail-worker      # start worker
just sail-discover    # preview issues
just sail-dry         # dry run
just sail-echo        # echo engine end-to-end test
just sail             # real run
```

## Configuration

Edit `tools/agentic/config.yaml`:

```yaml
planner:
  engine: claude        # claude | codex | echo
  model: claude-opus-4-6

implementer:
  engine: claude        # claude | codex | cursor | echo
  model: claude-sonnet-4-6

loop:
  max_tasks_per_run: 3
  max_retries_per_task: 2
  min_priority: 2        # 1=critical 2=high 3=normal (lower = more selective)
  interval_minutes: 360
  max_parallel: 1        # concurrent pipelines (1 = sequential)
```

Override per-run with env vars:
```bash
SAIL_MAX_TASKS=1 SAIL_MIN_PRIORITY=1 SAIL_PLANNER_ENGINE=echo sygaldry sail
```

All SAIL env vars: `SAIL_PLANNER_ENGINE`, `SAIL_PLANNER_MODEL`, `SAIL_IMPLEMENTER_ENGINE`,
`SAIL_IMPLEMENTER_MODEL`, `SAIL_MAX_TASKS`, `SAIL_MAX_RETRIES`, `SAIL_MIN_PRIORITY`,
`SAIL_MAX_PARALLEL`, `TEMPORAL_ADDRESS`, `TEMPORAL_NAMESPACE`, `TEMPORAL_TASK_QUEUE`.

## Temporal Step Types

### `agent_task`

Invokes a Claude, Codex, Cursor, or echo CLI as a pipeline step.

```yaml
- id: plan
  type: agent_task
  agent_task:
    engine: claude           # claude | codex | cursor | echo
    model: claude-opus-4-6
    prompt_file: tools/agentic/prompts/planner.md
    working_dir: /path/to/repo
    sandbox: workspace-write  # codex-only
    params:                   # injected into prompt_file as ${{ params.KEY }}
      issue_json: ${{ params.issue_json }}
      workflow_id: ${{ params.workflow_id }}
  timeout_seconds: 600
```

Params are also injected as `SAIL_PARAM_<KEY>` env vars into the agent subprocess.

### `git_op`

Dispatches to `tools/agentic/git_ops.sh` for six operations.

```yaml
- id: branch
  type: git_op
  git_op:
    op: branch           # branch | commit | push | create-pr | reset | delete-branch
    repo_dir: /path/to/repo
    branch: agentic/20260307-120000-fix-something
    base_branch: main
```

`commit` exits 1 when there is nothing to stage (prevents ghost PRs). `reset` saves
a diff patch to `/tmp/sail-<branch>-failed.patch` before discarding changes.

## Issue Sources

`discover_issues.py` scans seven sources:

| Source | Priority |
|--------|----------|
| Go test failures (`go test ./...`) | 1 (critical) |
| Go vet warnings (`go vet ./...`) | 2 (high) |
| shellcheck errors | 2 (high) |
| TODO/FIXME/HACK comments | 2–3 |
| shellcheck warnings | 3 (normal) |
| ruff lint findings | 3 (normal) |
| foundation.org file reference drift | 3 (normal) |
| Go functions with 0% test coverage | 3 (normal) |

## Deduplication

SAIL tracks attempted issues in `.agentic/attempted.jsonl` (gitignored):
```json
{"issue_id": "shellcheck-a1b2c3d4", "branch": "agentic/20260307-...", "status": "pr_created", "timestamp": "..."}
```
Issues with `status: pr_created` or `status: skipped` are not re-attempted. Remote
branch existence (`origin/agentic/*-<slug>`) is also checked before launching.

## Retry with Failure Context

On validation failure, SAIL captures the `validate_all.sh` stderr from the Temporal
log directory and writes it to `/tmp/sail-<issue_id>-failure.txt`. The retry run
passes `failure_context_file` as a param so the retry prompt can read the exact
failure output and guide the next attempt.

## Files

| File | Purpose |
|------|---------|
| `tools/agentic/config.yaml` | Model selection and loop parameters |
| `tools/agentic/improvement_loop.yaml` | Temporal YAML pipeline (8 steps) |
| `tools/agentic/run_improvement_loop.sh` | Outer loop: discover + orchestrate per issue |
| `tools/agentic/discover_issues.py` | Multi-source issue scanner (7 sources) |
| `tools/agentic/git_ops.sh` | Git operations helper (called by git_op activity) |
| `tools/agentic/prompts/planner.md` | Planner LLM prompt |
| `tools/agentic/prompts/implementer.md` | Implementer LLM prompt |
| `tools/agentic/prompts/retry.md` | Retry LLM prompt (on validate failure) |
| `temporal/internal/activities/agent_task.go` | AgentTask Temporal activity |
| `temporal/internal/activities/git_op.go` | GitOp Temporal activity |
| `justfile` | Common dev tasks (just sail, just sail-dry, just test, ...) |

## Safety

- Only opens PRs — never merges to main automatically.
- Validation gate (`validate_all.sh --quick`) must pass before any commit.
- Empty commits exit 1 before staging — no ghost PRs for zero-change runs.
- Failed attempts trigger rollback (hard reset + patch saved to `/tmp/`).
- `max_tasks_per_run` and `max_retries_per_task` cap compute usage.
- Deduplication prevents re-processing issues already handled across invocations.
- Uses separate `agentic/<timestamp>-<slug>` branches — never writes to main.
- Temporal preflight check aborts immediately if server is not reachable.
