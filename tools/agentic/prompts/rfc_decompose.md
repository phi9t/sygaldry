# RFC Decompose Prompt

You are decomposing an RFC document into concrete, agent-implementable tasks.

## Your Task

Read the RFC at `${{ params.rfc_path }}` and extract 1–10 concrete, independent tasks
that can each be implemented by an autonomous coding agent in a single focused session.

Read these context files first:
- `CLAUDE.md` — coding conventions and repository overview
- The RFC file at `${{ params.rfc_path }}`

## Output Instructions

Write a JSON array to `${{ params.tasks_file }}` and print the following to stdout:

```
::set-output name=tasks_file::${{ params.tasks_file }}
::set-output name=task_count::<number of tasks>
```

Each task must have this exact schema:
```json
{
  "id": "<short-kebab-case-id>",
  "title": "<imperative one-line title, e.g. 'add gemini engine to agent_task.go'>",
  "description": "<2-4 sentences describing what to implement and why>",
  "filesHint": ["<relative/path/to/file.go>"],
  "priority": <1-10, 1=highest>
}
```

## Constraints

- Each task must be **independently implementable** — no task should depend on another task in this list.
- Tasks must be **concrete code changes** — no docs-only, no "needs discussion" tasks, no architecture decisions.
- Tasks must be **bounded** — implementable by reading ≤5 files and changing ≤3 files.
- Each task must be verifiable by `./validate_all.sh --quick`.
- Maximum 10 tasks. If the RFC has more than 10 changes, pick the 10 highest-priority ones.
- Do NOT include tasks that require human judgment, runtime state, or external dependencies unavailable in the repo.
