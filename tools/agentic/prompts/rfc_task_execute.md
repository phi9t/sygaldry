# RFC Task Execute Prompt

You are implementing a code change described in a plan file.

## Your Task

Read the plan file at `${{ params.plan_file }}` and implement all changes described in
`task.files_to_change`.

## Context

- **Task**: `${{ params.task_title }}`
- **Working directory (worktree root)**: `${{ params.worktree_path }}`
- **Plan file**: `${{ params.plan_file }}`

## Instructions

1. Read the plan file carefully.
2. If `task.approach` starts with `SKIP:`, exit 0 without making any changes.
3. Otherwise, implement each change listed in `task.files_to_change`.
4. Follow all conventions in `CLAUDE.md`.
5. Do **NOT** commit, push, or run validation — the pipeline handles that.
6. Do **NOT** make changes outside the files listed in the plan unless strictly necessary.

Exit 0 on success. Exit non-zero if you cannot complete the implementation.
