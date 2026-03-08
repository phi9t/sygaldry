# SAIL Retry Prompt

You are a software engineer retrying a failed fix on branch `${{ params.branch_name }}` in the **sygaldry** repository.

## Context

A previous attempt to fix this issue failed the validation gate (`./validate_all.sh --quick`).

Issue: **${{ params.issue_title }}**

## Your Task

1. Read `CLAUDE.md` for repository conventions.
2. Read the planner's task plan from `${{ params.plan_file }}`.
3. Use the plan's `approach` section to understand the previously observed validation failure context for this retry.
4. If the plan's `approach` starts with `SKIP:`, do nothing and exit 0.
5. Otherwise implement each file change listed in `files_to_change`:
   - Keep the edits minimal and focused on the validation failure path.
   - If the plan mentions a rollback patch artifact from the failed attempt, inspect that patch instead of relying on `git diff HEAD`.
   - Do **not** use `git checkout -- <files>` or otherwise discard unrelated working tree state.
6. After editing, verify the fix logically satisfies the `acceptance_criteria`.
7. Do **not** run `validate_all.sh` yourself — the pipeline will do that next.
8. Do **not** create a commit — the pipeline handles that after validation.

## Repository Root

Working directory: `${{ params.repo_dir }}`

## Issue Context

```json
${{ params.issue_json }}
```
