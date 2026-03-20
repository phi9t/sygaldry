# RFC Task Execute Prompt

You are implementing a code change described in a plan file.

## Your Task

Read the plan file at `${{ params.plan_file }}` and implement all changes described in
`task.files_to_change`.

## Context

- **Task**: `${{ params.task_title }}`
- **Task description**: `${{ params.task_description }}`
- **RFC**: `${{ params.rfc_path }}` (read this for full background if needed)
- **Working directory (worktree root)**: `${{ params.worktree_path }}`
- **Plan file**: `${{ params.plan_file }}`

## Instructions

1. Read the plan file carefully.
2. If `task.approach` starts with `SKIP:`, exit 0 without making any changes.
3. Otherwise, implement **every** change listed in `task.files_to_change`. You MUST edit the
   actual files — reading them and confirming they exist is not sufficient.
4. Follow all conventions in `CLAUDE.md`.
5. Do **NOT** commit, push, or run validation — the pipeline handles that.
6. Do **NOT** make changes outside the files listed in the plan unless strictly necessary.

## Mandatory Self-Review Before Exiting

Before you exit, perform this checklist. Do not skip any step:

1. Run `git diff --stat` in the worktree. If the output is **empty**, you have NOT completed
   the task. Return to step 3 above and make the edits.
2. For each file listed in `task.files_to_change`, confirm it appears in `git diff --stat`.
3. Briefly re-read the changed sections to catch obvious mistakes (missing import, wrong
   variable name, copy-paste error).
4. If you find an issue, fix it before exiting.

Exit 0 only after the self-review confirms real changes were made.
Exit non-zero if you cannot complete the implementation even after retrying.
