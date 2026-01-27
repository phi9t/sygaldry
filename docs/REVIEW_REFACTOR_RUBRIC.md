# Review and Refactor Rubric

Use this rubric for every review/refactor PR.

## 1) Findings First (severity order)

Review output must list issues in this order:

1. Correctness bugs and behavior regressions.
2. Safety/reliability risks.
3. Interface contract breaks.
4. Missing tests or weak assertions.
5. Readability/maintainability issues.

Each finding should include:

- file path and line reference
- observed behavior
- expected behavior
- concrete fix direction

## 2) Refactor Acceptance Checklist

- [ ] Behavior parity proven (tests or equivalent artifact diff).
- [ ] Public interfaces unchanged, or changes documented and versioned.
- [ ] Tool scope remains bounded and explicit.
- [ ] Complex behavior is composed from smaller tools.
- [ ] Lint and formatting gates pass.
- [ ] Coverage ratchet gate passes.
- [ ] New edge cases are covered by tests.

## 3) Required Evidence in PR Description

1. Scope statement (in/out of scope).
2. Risk assessment.
3. Validation commands run and outcomes.
4. Coverage delta summary.
5. Waiver references, if any.

## 4) Review Questions

1. Is this code easier to read than before?
2. Is the behavior demonstrably the same (or intentionally changed with tests)?
3. Does each command/tool still have one clear responsibility?
4. Could any added complexity be split into composed sub-tools?
5. Are error paths explicit and actionable?

## 5) Blocking Conditions

Do not approve when any of the following is true:

- failing quality gates in strict mode
- undocumented contract/API changes
- coverage regression against baseline
- missing tests for changed control flow or failure paths
- ambiguous or overloaded tool responsibility

