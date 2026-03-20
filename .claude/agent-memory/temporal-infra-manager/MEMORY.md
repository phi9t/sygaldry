# Temporal Infra Manager Memory

## Key Architecture Patterns

### Naming: Types vs Workflow Functions
- Go does not allow a type and a function to share the same name in a package.
- When a workflow function represents a "task", name the data type `XxxSpec` or `XxxInput`
  and the function `XxxWorkflow` to avoid redeclaration errors.
- Example: `RFCTaskSpec` (type) + `RFCTaskWorkflow` (func), registered as `w.RegisterWorkflow(workflows.RFCTaskWorkflow)`.

### Activity Registration Pattern (worker/main.go)
All activities and workflows must be registered in `cmd/worker/main.go`.
After adding new activities/workflows, always add both `w.RegisterWorkflow(...)` and
`w.RegisterActivity(...)` calls.

### Workflow Function Signatures
- Parent workflow: `func XxxImpl(ctx workflow.Context, input XxxImplInput) (XxxImplResult, error)`
- Child workflow: `func XxxTaskWorkflow(ctx workflow.Context, input XxxTaskInput) (XxxTaskResult, error)`
- Activities called via `workflow.ExecuteActivity(ctx, activities.FuncName, input)`

### set-output Protocol
Bash scripts and agent activities communicate structured outputs via:
`::set-output name=key::value` lines on stdout.
Parse with `extractSetOutput(stdout, key)` in workflow code.

### Multi-Engine Fallback Pattern
`MultiEngineAgentTask` in `internal/activities/multi_engine.go`:
- Tries engines in order: cursor → gemini → opencode → codex (default)
- Exponential backoff between rounds: base * 2^round (default base=30s)
- Detects quota/rate-limit errors via `quotaPatterns` slice
- All retrying is internal — no Temporal retry policy needed on this activity

### Git Worktree Operations
Added to `git_ops.sh` and `git_op.go`: `worktree-add`, `worktree-commit`, `worktree-remove`, `worktree-land`
- Requires `--worktree-path` arg (maps to `GitOpInput.WorktreePath`)
- `worktree-land` cherry-picks the worktree HEAD commit onto base branch and pushes

## Key Files Added (RFC Impl Loop)
- `temporal/internal/activities/multi_engine.go` — MultiEngineAgentTask activity
- `temporal/internal/activities/file_ops.go` — ReadJSONFile activity
- `temporal/internal/workflows/rfc_impl.go` — RFCImpl + RFCTaskWorkflow workflows
- `temporal/cmd/rfc/main.go` — CLI to submit RFC impl workflows
- `tools/agentic/prompts/rfc_decompose.md` — decompose RFC → tasks.json
- `tools/agentic/prompts/rfc_task_plan.md` — plan a single task
- `tools/agentic/prompts/rfc_task_execute.md` — execute a plan
- `tools/agentic/prompts/rfc_task_review.md` — review implementation

## Engine Constants (agent_task.go)
- AgentEngineClaude, AgentEngineCodex, AgentEngineCursor, AgentEngineEcho
- AgentEngineGemini (`gemini -p "<prompt>" --yolo [--model <model>]`)
- AgentEngineOpenCode (`opencode run "<prompt>" [--model <model>]`)

## Test Count
After RFC impl: 6 packages pass (activities, workflows, orchestrate, worker, run, rfc cmd).
`go test ./...` from `temporal/` is the canonical verification command.
