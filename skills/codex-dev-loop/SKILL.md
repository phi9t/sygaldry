---
name: codex-dev-loop
description: Run a structured two-agent development loop where Codex implements changes and an outer reviewer critiques and requests revisions before testing. Use when you want repeatable implement-review-test cycles with JSONL logs and bounded revision/test-fix attempts.
---

# codex-dev-loop

Two-agent development loop: **Codex** (coder, unrestricted mode) implements features while **Claude Code** (outerloop reviewer) critiques code quality, demands revisions, and enforces test coverage.

## Overview

The outerloop agent (you, Claude Code) orchestrates three phases:

1. **Implement** — Codex writes the code
2. **Critique** — You review and request revisions (up to `MAX_REVISIONS` iterations)
3. **Test** — Codex writes tests, you run them, Codex fixes failures (up to `MAX_TEST_FIXES` iterations)

## Skill Path Setup

Use these commands so examples work from any current directory:

```bash
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SKILL_DIR="$CODEX_HOME/skills/codex-dev-loop"
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CODEX_DEV_LOOP_MODEL` | `o3` | Model for Codex invocations |
| `CODEX_DEV_LOOP_MAX_REVISIONS` | `3` | Max critique/revision iterations |
| `CODEX_DEV_LOOP_MAX_TEST_FIXES` | `2` | Max test-fix iterations |
| `CODEX_DEV_LOOP_OUTPUT_DIR` | `/tmp/codex-dev-loop` | Working directory for prompt/output files |

## Scripts

| Script | Purpose |
|--------|---------|
| `$SKILL_DIR/scripts/codex_run.sh` | Codex CLI wrapper with JSONL logging |

### codex_run.sh Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--prompt` | Prompt text (required unless `--prompt-file`) | — |
| `--prompt-file` | Read prompt from file (for long prompts) | — |
| `--model` | Model to use | `o3` |
| `--workdir` | Working directory for Codex | `.` |
| `--output` | File to write final message to | — |

## Protocol

### Phase 1: Implement

1. Construct an implementation prompt containing:
   - Feature requirements from the user
   - Relevant file paths and code context
   - Repository conventions (from CLAUDE.md or similar)
2. Write prompt to `$OUTPUT_DIR/implement-prompt.md`
3. Invoke:
   ```bash
   "$SKILL_DIR/scripts/codex_run.sh" \
     --prompt-file "$OUTPUT_DIR/implement-prompt.md" \
     --workdir <project-root> \
     --output "$OUTPUT_DIR/implement-output.txt"
   ```
4. Read Codex output and run `git diff` to see all changes

### Phase 2: Critique (max `MAX_REVISIONS` iterations)

Evaluate the diff against this **7-point checklist**:

| # | Criterion | What to check |
|---|-----------|---------------|
| 1 | **Correctness** | Does the code do what was asked? Edge cases handled? |
| 2 | **Readability** | Clear naming, reasonable function size, no dead code? |
| 3 | **Complexity** | Over-engineered? Premature abstractions? |
| 4 | **Architecture** | Fits existing patterns? No layering violations? |
| 5 | **Error handling** | Failures caught at boundaries? No swallowed errors? |
| 6 | **Security** | No injection vectors, hardcoded secrets, or unsafe patterns? |
| 7 | **Conventions** | Follows repo style (shell headers, logging, naming)? |

**Scoring:** Rate each criterion pass/fail. If any fail:

1. Construct a revision prompt with **specific file:line references** and what to fix
2. Write to `$OUTPUT_DIR/revision-N-prompt.md`
3. Re-invoke Codex:
   ```bash
   "$SKILL_DIR/scripts/codex_run.sh" \
     --prompt-file "$OUTPUT_DIR/revision-N-prompt.md" \
     --workdir <project-root> \
     --output "$OUTPUT_DIR/revision-N-output.txt"
   ```
4. Re-evaluate the updated diff

After `MAX_REVISIONS` iterations: accept with warnings and proceed to testing.

### Phase 3: Test (max `MAX_TEST_FIXES` iterations)

1. Identify changed files from `git diff --name-only`
2. Construct a test prompt listing:
   - Changed files and their public interfaces
   - Expected behaviors to cover
   - Test framework to use (auto-detect: pytest / go test / jest / cargo test)
3. Write to `$OUTPUT_DIR/test-prompt.md`
4. Invoke Codex to write tests:
   ```bash
   "$SKILL_DIR/scripts/codex_run.sh" \
     --prompt-file "$OUTPUT_DIR/test-prompt.md" \
     --workdir <project-root> \
     --output "$OUTPUT_DIR/test-output.txt"
   ```
5. Run the tests using the detected framework
6. If tests fail: construct a fix prompt with test output, re-invoke Codex (up to `MAX_TEST_FIXES`)
7. If tests still fail after all fix iterations: report failures to the user

## Prompt Templates

### Implementation Prompt

```markdown
## Task
<user's feature request>

## Context
Repository: <repo path>
Key files:
- <file1>: <description>
- <file2>: <description>

## Conventions
- <convention 1>
- <convention 2>

## Instructions
Implement the feature described above. Follow the repository conventions.
Write clean, minimal code — no over-engineering.
```

### Revision Prompt

```markdown
## Revision Request

The following issues were found in your implementation:

### Issue 1: <criterion name>
**File:** `<file>:<line>`
**Problem:** <description>
**Fix:** <what to do>

### Issue 2: ...

## Instructions
Fix each issue listed above. Do not introduce new features or refactor unrelated code.
```

### Test Generation Prompt

```markdown
## Test Generation

Write tests for the following changed files:

### Changed Files
- `<file1>`: <what changed>
- `<file2>`: <what changed>

### Requirements
- Test framework: <pytest|go test|jest|cargo test>
- Cover: happy path, edge cases, error conditions
- Test file location: <path>

### Do NOT
- Mock internal implementation details
- Write tests for unchanged code
- Over-test trivial getters/setters
```

### Test Fix Prompt

```markdown
## Test Failures

The following tests failed:

```
<test output>
```

### Instructions
Fix the failing tests. The issue may be in the test code OR the implementation.
If the implementation has a bug, fix it. If the test expectation is wrong, fix the test.
Do not delete failing tests — fix them.
```

## Prerequisites

- `codex` CLI installed and on PATH
- `OPENAI_API_KEY` environment variable set
- Git repository (for diff-based review)

## Example Session

```bash
# Set up output directory
export CODEX_DEV_LOOP_OUTPUT_DIR=/tmp/codex-dev-loop
mkdir -p "$CODEX_DEV_LOOP_OUTPUT_DIR"

# Phase 1: Implement
"$SKILL_DIR/scripts/codex_run.sh" --prompt-file "$CODEX_DEV_LOOP_OUTPUT_DIR/implement-prompt.md" \
  --workdir /path/to/project --output "$CODEX_DEV_LOOP_OUTPUT_DIR/implement-output.txt"

# Phase 2: Review diff, write revision prompt if needed
git diff
"$SKILL_DIR/scripts/codex_run.sh" --prompt-file "$CODEX_DEV_LOOP_OUTPUT_DIR/revision-1-prompt.md" \
  --workdir /path/to/project --output "$CODEX_DEV_LOOP_OUTPUT_DIR/revision-1-output.txt"

# Phase 3: Generate and run tests
"$SKILL_DIR/scripts/codex_run.sh" --prompt-file "$CODEX_DEV_LOOP_OUTPUT_DIR/test-prompt.md" \
  --workdir /path/to/project --output "$CODEX_DEV_LOOP_OUTPUT_DIR/test-output.txt"
pytest tests/
```
