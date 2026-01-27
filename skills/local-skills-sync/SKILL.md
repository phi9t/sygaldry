---
name: local-skills-sync
description: Keep the repo-scoped skill index synchronized with the filesystem by generating and validating `skills/LOCAL_SKILLS.md` from actual `skills/*/SKILL.md` directories. Use when adding/removing/renaming local skills, reviewing skill metadata drift, or preparing commits that touch `skills/`.
---

# Local Skills Sync

Keep one canonical index of local skills (`skills/LOCAL_SKILLS.md`) accurate and deterministic.

## Workflow

1. Regenerate the index after any skill directory change:
   ```bash
   python3 skills/local-skills-sync/scripts/sync_local_skills.py
   ```
2. Verify no drift in review/CI:
   ```bash
   python3 skills/local-skills-sync/scripts/sync_local_skills.py --check
   ```
3. If `--check` fails, rerun without `--check` and commit updated `skills/LOCAL_SKILLS.md`.

## What The Script Syncs

- Discovers local skills from directories matching `skills/*/SKILL.md`.
- Rebuilds `skills/LOCAL_SKILLS.md` in a stable, sorted format.
- Pulls each skill summary from frontmatter `description`; if absent, uses the first body paragraph.
- Lists common resource paths when present (validation, scripts, references, assets, envs, portable, agent metadata).

## Commands

```bash
# Write updated index
python3 skills/local-skills-sync/scripts/sync_local_skills.py

# Check only (non-zero exit on drift)
python3 skills/local-skills-sync/scripts/sync_local_skills.py --check

# Custom output path (optional)
python3 skills/local-skills-sync/scripts/sync_local_skills.py --output /tmp/LOCAL_SKILLS.md
```

## Scope

- This skill manages sync for `skills/LOCAL_SKILLS.md`.
- It does not install skills into `$CODEX_HOME/skills`.
