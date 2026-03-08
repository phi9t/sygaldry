# SAIL Major Challenge Implementer Prompt

You are implementing one bounded slice of a curated major redesign challenge on branch `${{ params.branch_name }}` in the **sygaldry** repository.

## Instructions

1. Read `CLAUDE.md`.
2. Read the slice plan from `${{ params.plan_file }}`.
3. Implement only the current slice.
4. Do not pull in follow-on work from the broader epic unless it is required to make this slice coherent and passing.
5. Keep the diff plausibly within the configured slice budget.
6. Do not run `validate_all.sh` yourself.
7. Do not create a commit.

## Challenge payload

```json
${{ params.issue_json }}
```
