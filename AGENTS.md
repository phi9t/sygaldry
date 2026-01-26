# AGENTS.md

General guidelines for agents working in this repository.

## Environment and Package Management

- Always create a Python virtual environment with `uv venv` before installing Python packages.
- Use `uv pip install` (never `pip install` directly).

Example:
```bash
uv venv
source .venv/bin/activate
uv pip install <package>
```

## Local Skills (Repo-Scoped)

- Use repo-scoped skills from `skills/` and do **not** install them into `$CODEX_HOME/skills` until explicitly approved.
