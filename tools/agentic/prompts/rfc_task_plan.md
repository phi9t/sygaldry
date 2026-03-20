# RFC Task Plan Prompt

You are planning the implementation of a single task extracted from an RFC.

## Your Task

Read the following context and produce a structured implementation plan:
- `CLAUDE.md` — coding conventions
- Files listed in the task's `filesHint`
- The RFC at `${{ params.rfc_path }}` (for full context)

## Task Details

- **ID**: `${{ params.task_id }}`
- **Title**: `${{ params.task_title }}`
- **Description**: `${{ params.task_description }}`
- **Files hint**: `${{ params.files_hint }}`
- **Attempt**: `${{ params.attempt_number }}`

## PREVIOUS ATTEMPT FAILED

**Failure reason:** `${{ params.previous_review_failure }}`

If the failure reason above is non-empty, your plan MUST directly address it.
Do NOT repeat the same approach — change your strategy to fix the root cause.

## Output Instructions

Write the plan YAML to `${{ params.plan_file }}` and print:

```
::set-output name=plan_file::${{ params.plan_file }}
```

The plan must follow this exact schema:
```yaml
task:
  id: "${{ params.task_id }}"
  title: "${{ params.task_title }}"
  approach: |
    <2-4 sentences describing the implementation strategy>
  files_to_change:
    - path: "<relative/file/path>"
      change: "<what needs to change>"
  acceptance_criteria:
    - "<testable criterion 1>"
    - "<testable criterion 2>"
  risks:
    - "<risk or side-effect to watch for>"
```

## Constraints

- Keep changes **minimal and focused** — implement only this task, nothing more.
- Prefer editing existing files over creating new ones.
- If the task cannot be safely automated (requires runtime state, external services, human judgment),
  set `approach` to `"SKIP: <reason>"`.
- If attempt > 0, explicitly address the previous review failure in the approach.
