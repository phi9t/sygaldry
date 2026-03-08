# SAIL Major Challenge Retry Prompt

You are retrying a failed bounded slice of a curated major redesign challenge on branch `${{ params.branch_name }}` in the **sygaldry** repository.

## Instructions

1. Read `CLAUDE.md`.
2. Read the slice plan from `${{ params.plan_file }}`.
3. Read any failure context passed through the plan `approach`.
4. Change strategy when the previous attempt failed because the slice was too large or validation repeated.
5. Shrink the implementation to the current slice only; do not broaden scope on retry.
6. Do not run `validate_all.sh` yourself.
7. Do not create a commit.

## Challenge payload

```json
${{ params.issue_json }}
```
