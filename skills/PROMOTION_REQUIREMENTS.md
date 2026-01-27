# Skill Promotion Requirements

This document defines the promotion bar for moving a repo-scoped skill (`skills/`) to a global skill (`$CODEX_HOME/skills`).

## Promotion Goal

Promoted skills must be usable outside this repository and must not depend on the `sygaldry` repo layout.

Hermeticity level:
- Self-contained + standard CLIs

Allowed runtime dependencies:
- `bash`
- `python3`
- `git`
- `docker`
- `codex`

Skill-scoped exception:
- `zephyr` MLSys env scripts may require `PyYAML` at runtime.
  - Scripts must fail fast with a clear install hint when `PyYAML` is missing.

## Hard Gates (Must Pass)

1. Packaging gate
- Skill folder includes `SKILL.md`.
- Skill folder includes `agents/openai.yaml`.
- All required scripts/references/assets are inside the skill directory.

2. Hermeticity gate
- No required references to repo-scoped paths such as:
  - `/workspace/`
  - `./container/`
  - `.sygaldry/`
  - repo-root `tools/` commands
  - absolute paths for this repo checkout
- Examples in `SKILL.md` run using skill-local paths.

3. Interface gate
- Public script interfaces are documented (`--help`, flags, expected behavior).
- Error behavior is explicit for missing required arguments/prereqs.

4. Validation gate
- `python3 /home/phi9t/.codex/skills/.system/skill-creator/scripts/quick_validate.py <skill-dir>`
- `shellcheck -s bash -S warning` on shell scripts in the skill.
- `python3 -m py_compile` on Python scripts in the skill.
- Hermetic audit passes:
  - `python3 skills/hermetic-skill-audit.py <skill-dir>`

5. Install smoke gate
- Install into a temp `$CODEX_HOME`.
- Invoke quick-start commands from outside this repo.
- Confirm no call path requires files under `sygaldry`.

## Promotion Workflow

1. Select candidate skills and freeze scope.
2. Vendor all required materials into each skill directory.
3. Replace repo-relative examples with global skill path examples:
   ```bash
   CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
   SKILL_DIR="$CODEX_HOME/skills/<skill-name>"
   "$SKILL_DIR/scripts/<script>.sh" ...
   ```
4. Run hard-gate validation commands.
5. Install candidate skill(s) into `$CODEX_HOME/skills`.
6. Run smoke tests.
7. Announce promotion and require Codex restart to load changes.

## Current Promotion Wave

First wave:
1. `codex-headless`
2. `codex-dev-loop`

Deferred until de-coupled from repo infra:
- `zephyr`
