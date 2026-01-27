---
name: codex-headless
description: Run OpenAI Codex CLI in headless (`exec`) mode for non-interactive code generation, review, and editing. Use when you need scripted Codex runs, reproducible CLI workflows, or JSON output without interactive chat.
---

# codex-headless

Run OpenAI Codex CLI in headless (`exec`) mode for non-interactive code generation, review, and editing.

## Skill Path Setup

Use these commands so examples work from any current directory:

```bash
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SKILL_DIR="$CODEX_HOME/skills/codex-headless"
```

## Usage

```bash
# Basic execution
"$SKILL_DIR/scripts/codex_exec.sh" --prompt "Refactor main.py to use async/await"

# With model selection and working directory
"$SKILL_DIR/scripts/codex_exec.sh" --prompt "Add unit tests for utils.go" --model o4-mini --workdir /path/to/project

# Capture output to file
"$SKILL_DIR/scripts/codex_exec.sh" --prompt "Review this code for bugs" --output review.txt

# Custom sandbox mode
"$SKILL_DIR/scripts/codex_exec.sh" --prompt "Generate a Makefile" --sandbox read-only
```

## Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--prompt` | Prompt text (required) | — |
| `--model` | Model to use (`o3`, `o4-mini`, `gpt-4.1`) | `o4-mini` |
| `--workdir` | Working directory for codex | `.` |
| `--output` | File to write final message to | — |
| `--sandbox` | Sandbox mode (`read-only`, `workspace-write`, `danger-full-access`) | `workspace-write` |

## Common Patterns

**Code generation:**
```bash
"$SKILL_DIR/scripts/codex_exec.sh" --prompt "Create a Python HTTP server with health check endpoint" --workdir ./src
```

**Code review:**
```bash
"$SKILL_DIR/scripts/codex_exec.sh" --prompt "Review the diff in staged changes for security issues" --sandbox read-only
```

**File editing:**
```bash
"$SKILL_DIR/scripts/codex_exec.sh" --prompt "Add error handling to all database calls in db.py" --output changes.txt
```

## Prerequisites

- `codex` CLI installed and on PATH
- `OPENAI_API_KEY` environment variable set
