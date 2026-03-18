# RFC-025: Fix PYTHON_VERSION Default Mismatch Between Bash and Rust

**Status:** Proposed
**Priority:** High
**Effort:** XS
**Area:** shell / rust-core

## Problem

`PYTHON_VERSION` has two different defaults in two different launchers:

| File | Default |
|------|---------|
| `container/launch_container.sh` line 76 | `3.12` |
| `crates/zephyr/src/config.rs` line 164 | `3.13` |

Whichever launcher is invoked without an explicit `PYTHON_VERSION` env var will produce a container built for a different Python version. Since the Spack environment pins Python 3.13 (per the memory notes: "Python 3.13.8"), the bash default of `3.12` is actively wrong and will cause `spack-env-activate` to fail inside the container.

## Evidence

`container/launch_container.sh` line 76:
```bash
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
```

`crates/zephyr/src/config.rs` line 164:
```rust
python_version: env_or("PYTHON_VERSION", "3.13"),
```

`MEMORY.md` confirms the Spack stack uses Python 3.13.8.

## Proposed Changes

1. Change the bash default to `3.13`:
   ```bash
   PYTHON_VERSION="${PYTHON_VERSION:-3.13}"
   ```

2. Add a comment in both files pointing to the other as the canonical source so the two stay in sync:
   ```bash
   # Keep in sync with crates/zephyr/src/config.rs PYTHON_VERSION default.
   PYTHON_VERSION="${PYTHON_VERSION:-3.13}"
   ```

3. Add a ShellCheck-compatible note and a CI check that greps both files to assert they agree:
   ```bash
   bash_default=$(grep 'PYTHON_VERSION:-' container/launch_container.sh | grep -o '[0-9.]*')
   rust_default=$(grep 'PYTHON_VERSION.*3\.' crates/zephyr/src/config.rs | grep -o '"3\.[0-9]*"' | tr -d '"')
   [[ "$bash_default" == "$rust_default" ]] || { echo "PYTHON_VERSION default mismatch"; exit 1; }
   ```

## Files Changed

- `container/launch_container.sh` — change `3.12` to `3.13` on the default line
- `crates/zephyr/src/config.rs` — add sync comment
- `validate_all.sh` — optionally add a version-agreement check

## Verification

```bash
grep 'PYTHON_VERSION:-' container/launch_container.sh
# Must show 3.13

grep 'PYTHON_VERSION' crates/zephyr/src/config.rs
# Must show "3.13"

cd crates/zephyr && cargo test
```
