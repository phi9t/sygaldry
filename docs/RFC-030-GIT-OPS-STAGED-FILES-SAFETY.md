# RFC-030: git_ops.sh Should Not Stage Sensitive Files with git add -A

**Status:** Proposed
**Priority:** High
**Effort:** S
**Area:** agentic / shell

## Problem

The `commit` and `worktree-commit` operations in `tools/agentic/git_ops.sh` use `git add -A` to stage all changes before committing. In an agentic context where LLM agents write files freely, `git add -A` risks staging:

- `.env` files or credentials accidentally written by an agent
- Large binary artifacts (model checkpoints, compiled objects)
- Temporary files that should not enter the repository

Because SAIL agents run with `--permission-mode acceptEdits`, they can write any file in the repository. A single confused agent could write a `.env` file containing a token, and `git add -A` would stage it.

## Evidence

`tools/agentic/git_ops.sh` line 108 (`commit` op):
```bash
git add -A
```

`tools/agentic/git_ops.sh` line 197 (`worktree-commit` op):
```bash
git add -A
```

The `.gitignore` is the only safeguard, but `.gitignore` does not cover all possible credential file names, and agents could create files with arbitrary names.

## Proposed Changes

1. Replace `git add -A` with a staged-file approach that excludes known-sensitive patterns:
   ```bash
   git add -A
   # Unstage any accidentally staged sensitive files
   git reset HEAD -- '*.env' '.env*' '*credentials*' '*secret*' '*token*' 2>/dev/null || true
   # Warn if any sensitive file is staged
   if git diff --cached --name-only | grep -Ei '\.env$|credentials|secrets?|tokens?'; then
       log "WARNING: sensitive file detected in staged changes — removing from stage"
       git diff --cached --name-only | grep -Ei '\.env$|credentials|secrets?|tokens?' | \
           xargs -r git reset HEAD --
   fi
   ```

2. Alternatively, use `git add --update` (stages only tracked files) as the primary mechanism and only stage new files explicitly listed by the agent.

3. Add a `--dry-run` flag to the `commit` op that prints what would be staged without actually staging or committing, to aid debugging.

## Files Changed

- `tools/agentic/git_ops.sh` — `commit` and `worktree-commit` operations

## Verification

```bash
shellcheck -s bash -S warning tools/agentic/git_ops.sh
# Create a test directory, add a .env file, run commit op, verify .env is NOT staged.
```
