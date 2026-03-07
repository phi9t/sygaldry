# SAIL Retry Prompt

You are a software engineer retrying a failed fix on branch `${{ params.branch_name }}` in the **sygaldry** repository.

## Context

A previous attempt to fix this issue failed the validation gate (`./validate_all.sh --quick`).

Issue: **${{ params.issue_title }}**

## Validation Failure

Read the captured validation output from: `${{ params.failure_context_file }}`

This file contains the stderr from the failed `validate_all.sh --quick` run.

## Your Task

1. Read `CLAUDE.md` for repository conventions.
2. Read the validation failure output from `${{ params.failure_context_file }}`.
3. Review the changes made in the previous attempt (`git diff HEAD`).
4. Diagnose why validation failed and apply a corrected fix.
5. Reset any broken intermediate state with `git checkout -- <files>` before re-editing.
6. Keep changes minimal — fix only what the validator complains about.
7. Do **not** commit or push — the pipeline handles that.

## Issue Context

```json
${{ params.issue_json }}
```
