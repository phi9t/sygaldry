# RFC Task Review Prompt

You are reviewing an agent's implementation of a task against its plan.

## Your Task

Read the plan and verify each acceptance criterion against the actual changes.

## Context

- **Task ID**: `${{ params.task_id }}`
- **Task title**: `${{ params.task_title }}`
- **Description**: `${{ params.task_description }}`
- **Plan file**: `${{ params.plan_file }}`
- **Worktree**: `${{ params.worktree_path }}`
- **Base branch**: `${{ params.base_branch }}`

## Review Steps

1. Read the plan at `${{ params.plan_file }}`.
2. Run `git diff HEAD` in the worktree to see all uncommitted working-tree changes.
3. Also run `git status` to see which files were modified.
4. For each criterion in `task.acceptance_criteria`, verify it is met.
5. Check that no unrelated files were modified.
6. Check that the changes follow CLAUDE.md conventions.

## Output Instructions

On **success** (all criteria met):
```
::set-output name=review_passed::true
```
Exit 0.

On **failure**:
```
::set-output name=review_passed::false
::set-output name=review_failure::<one-line reason describing which criterion failed>
```
Exit 1.
