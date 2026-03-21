# RFC Task Review — Stage 2: Code Quality

Spec compliance already passed. Now assess whether the implementation is clean and maintainable.

## Context

- **Task**: `${{ params.task_title }}`
- **Plan file**: `${{ params.plan_file }}`
- **Worktree**: `${{ params.worktree_path }}`
- **Base branch**: `${{ params.base_branch }}`

## Review Checklist

Run `git diff HEAD` and assess the changed code against these criteria:

1. **CLAUDE.md conventions** — no docstrings/comments on unchanged code, no premature abstractions,
   no backwards-compat shims, no over-engineering.
2. **Correctness** — no obvious logic errors, no introduced nil-pointer / index-out-of-bounds risks.
3. **Minimal scope** — no unrequested features or refactors beyond what the task requires.
4. **Test hygiene** — if new tests were added, they actually test the intended behaviour.
5. **No regressions** — unchanged behaviour is preserved; function signatures not silently altered.

Minor style nits do not constitute failure. Fail only on **Critical** or **Important** issues
(logic errors, CLAUDE.md violations, scope creep beyond what is defensible).

## Output

On **pass**:
```
::set-output name=review_passed::true
```
Exit 0.

On **fail**:
```
::set-output name=review_passed::false
::set-output name=review_failure::<one-line issue description, Critical or Important, file:line>
```
Exit 1.
