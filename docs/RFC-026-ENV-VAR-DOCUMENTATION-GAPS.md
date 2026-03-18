# RFC-026: Fill Env Var Documentation Gaps in CLAUDE.md

**Status:** Proposed
**Priority:** Low
**Effort:** XS
**Area:** docs

## Problem

Several env vars accepted by the Rust binary and bash launcher are absent from `CLAUDE.md`, making it impossible for contributors to discover them without reading source code. Conversely, some vars documented in `CLAUDE.md` are deprecated or renamed but the docs don't clearly distinguish legacy from current.

## Evidence

Vars present in `crates/zephyr/src/config.rs` or `container/launch_container.sh` but absent from the "Environment Variables" section of `CLAUDE.md`:

| Variable | Where defined | Purpose |
|----------|--------------|---------|
| `SYGALDRY_EXTRA_DOCKER_ARGS` | `launch_container.sh` ~line 488 | Appends raw docker run args |
| `ZEPHYR_SHARED_ROOT` | `config.rs` | Root dir override for shared caches |
| `ZEPHYR_BUILD_ROOT` | `config.rs` | Build root override |
| `ZEPHYR_META_ROOT` | `config.rs` | Metadata root override |
| `GO_VERSION` | `launch_container.sh` | Injected into container |
| `BAZEL_VERSION` | `launch_container.sh` | Injected into container |
| `SYGALDRY_BUILD_IMAGE` | `config.rs` line 339 | Build policy override (`always`/`if-missing`/`never`) |

The deprecated `SYGALDRY_*` vars are listed but without a clear "deprecated" badge and without the new `ZEPHYR_*` equivalents being shown as the recommended alternative inline.

## Proposed Changes

1. Add a "**Deprecated**" badge prefix to each `SYGALDRY_*` entry in CLAUDE.md.
2. Add all missing vars to the Environment Variables table with a description column.
3. Add a subsection "**Build control**" with `SYGALDRY_BUILD_IMAGE` / `ZEPHYR_BUILD_POLICY` documented.
4. For each deprecated var, include an inline pointer: `Deprecated: use ZEPHYR_X instead.`

## Files Changed

- `CLAUDE.md` — Environment Variables section

## Verification

Manual review: every env var accepted in `crates/zephyr/src/config.rs` and `container/launch_container.sh` should appear in `CLAUDE.md`.

```bash
# Extract all env_or / envOr / VARIABLE:-default patterns from both sources
grep -h 'env_or\|envOr\|:-' \
  crates/zephyr/src/config.rs container/launch_container.sh \
  | grep -oE '[A-Z][A-Z0-9_]{3,}' | sort -u
# Compare with CLAUDE.md manually.
```
