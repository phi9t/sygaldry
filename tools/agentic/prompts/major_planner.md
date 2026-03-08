# SAIL Major Challenge Planner Prompt

You are planning one bounded implementation slice for a curated major redesign challenge in the **sygaldry** repository.

## Inputs

- Repository root: `${{ params.repo_dir }}`
- Workflow ID: `${{ params.workflow_id }}`
- Branch: `${{ params.branch_name }}`
- Challenge payload:

```json
${{ params.issue_json }}
```

## Required reads

1. `CLAUDE.md`
2. `foundation.org`
3. Each path in `contextFiles` from the challenge payload, if it exists
4. The existing `epicPlanFile`, if it exists

## Your job

Plan exactly one bounded slice for this challenge. The slice must be small enough to land safely in a single unattended SAIL run.

Hard limits:
- Keep the slice cohesive.
- Do not plan speculative follow-on work.
- Prefer touching the fewest files needed for this slice.
- The resulting diff must plausibly fit under the configured slice guard.

## Files you must write

1. Update or create the challenge epic plan at `epicPlanFile`.
   - Summarize the overall challenge.
   - List completed slices, current slice, and likely remaining slices.
2. Write the current slice plan YAML to `/tmp/sail-${{ params.workflow_id }}-major-plan.yaml` using this exact schema:

```yaml
task:
  issue_id: "<id from issue_json>"
  title: "<commit-ready lowercase imperative title>"
  approach: |
    <bounded slice strategy>
  files_to_change:
    - path: "<relative file path>"
      change: "<what this slice changes>"
  acceptance_criteria:
    - "<criterion>"
  risks:
    - "<risk>"
```

3. Write JSON metadata to `sliceStateFile` with this shape:

```json
{
  "sliceIndex": <int>,
  "sliceTitle": "<same task title>",
  "postSuccessChallengeStatus": "active|complete"
}
```

Use `postSuccessChallengeStatus="complete"` only when this slice finishes the challenge according to `completionCriteria`.

## Stdout contract

Print exactly these lines after writing the files:

```text
::set-output name=plan_file::/tmp/sail-${{ params.workflow_id }}-major-plan.yaml
::set-output name=task_title::<task.title>
```
