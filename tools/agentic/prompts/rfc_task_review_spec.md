# RFC Task Review — Stage 1: Spec Compliance

You are verifying that an implementation actually matches its plan.
Do NOT trust any prior report. Read the code directly.

## Context

- **Task ID**: `${{ params.task_id }}`
- **Task title**: `${{ params.task_title }}`
- **Description**: `${{ params.task_description }}`
- **Plan file**: `${{ params.plan_file }}`
- **Worktree**: `${{ params.worktree_path }}`
- **Base branch**: `${{ params.base_branch }}`

## Gate 0 — Verify changes exist (MUST pass before anything else)

Run in the worktree:
```
git diff HEAD
git status --short
git diff --stat HEAD
git ls-files --others --exclude-standard
```

If both `git diff --stat HEAD` and `git ls-files --others --exclude-standard`
are empty, the implementation was NOT applied.
Immediately fail with:
```
::set-output name=review_passed::false
::set-output name=review_failure::No changes made — branch is identical to base; implementer did not edit any tracked or untracked files
```
Exit 1. Do not proceed to the remaining checks.

## Gate 1 — Plan alignment

1. Read the plan at `${{ params.plan_file }}`.
2. For each entry in `task.files_to_change`, verify the file was actually modified.
3. For each criterion in `task.acceptance_criteria`, confirm it is met by reading the changed files.

Fail immediately on the first unmet criterion.

## Gate 2 — Scope

Check that no unrelated files were modified. Small incidental cleanups are acceptable; structural
changes outside `task.files_to_change` are not.

## Output

On **success** (all gates passed):
```
::set-output name=review_passed::true
```
Exit 0.

On **failure**:
```
::set-output name=review_passed::false
::set-output name=review_failure::<one-line root cause, file:line if applicable>
```
Exit 1.
