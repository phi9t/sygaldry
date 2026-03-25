# RFC-081: Decompose docker_args.rs into docker_env.rs and docker_mounts.rs

**Status:** Open
**Date:** 2026-03-25
**Priority:** Low
**Effort:** M

---

## Problem

`crates/zephyr/src/host/docker_args.rs` is 938 lines and conflates three
distinct concerns:

1. **Environment variable building** (lines 47–108): `build_env_args`
2. **Volume mount building** (lines 110–285): `push_mount`, `build_volume_mounts`,
   `build_mode_mounts`
3. **Orchestration / final args assembly** (lines 286–362): `build`,
   `build_rust_mode`, and supporting helpers

Each concern has independent inputs and independent test sections. Mixing them
makes each harder to read and unit-test in isolation.

---

## Solution

Extract into two new sibling files. The actual function layout in the current
file (lines from `docker_args.rs`) is:

| Lines    | Item                          | Destination        |
|----------|-------------------------------|--------------------|
| 5–18     | `struct Mount` + `impl Mount` | `docker_mounts.rs` |
| 21–44    | `resolve_entrypoint_path`     | `docker_mounts.rs` |
| 47–107   | `build_env_args`              | `docker_env.rs`    |
| 110–126  | `push_mount`                  | `docker_mounts.rs` |
| 129–234  | `build_volume_mounts`         | `docker_mounts.rs` |
| 235–280  | `build_mode_mounts`           | `docker_mounts.rs` |
| 286–464  | `build`, `build_rust_mode`, `detect_user_spec`, `dev_sudo_enabled`, `atty_stdin` | retained in `docker_args.rs` |

**`crates/zephyr/src/host/docker_env.rs`:**
- `pub(crate) fn build_env_args` and its imports
  (`use crate::config::ZephyrConfig; use crate::paths::container_paths;`)
- Move the "build_env_args tests" section into its `#[cfg(test)]` block

**`crates/zephyr/src/host/docker_mounts.rs`:**
- `pub(crate) struct Mount` + `impl Mount`
- `pub(crate) fn resolve_entrypoint_path`
- `fn push_mount` (private to this module)
- `pub(crate) fn build_volume_mounts`
- `pub(crate) fn build_mode_mounts`
- Required imports: `use crate::config::{LaunchMode, ZephyrConfig};`,
  `use crate::paths::{container_paths, resolve_mount_path};`,
  `use crate::error::Result;`, `use std::path::PathBuf;`
- Move the Mount tests and resolve_entrypoint_path tests into its `#[cfg(test)]` block

**`docker_args.rs` retains:**
- `use super::docker_env::build_env_args;`
- `use super::docker_mounts::{Mount, build_volume_mounts, build_mode_mounts, resolve_entrypoint_path};`
- `build`, `build_rust_mode`, `detect_user_spec`, `dev_sudo_enabled`, `atty_stdin`
- The `detect_user_spec` tests, `dev_sudo_enabled` inline usage, and full `build()` integration tests

**`crates/zephyr/src/host/mod.rs`:** add `pub mod docker_env; pub mod docker_mounts;`
before the existing `pub mod docker_args;` line.

**Ordering:** Create `docker_env.rs` and `docker_mounts.rs` first, then edit
`docker_args.rs` to replace the moved items with `use` imports, then edit
`mod.rs` to register the new modules. Verify `cargo build -p zephyr` after
each file creation before proceeding.

---

## Acceptance Criteria

1. `crates/zephyr/src/host/docker_env.rs` and `docker_mounts.rs` both exist
2. `docker_args.rs` reduced to ≤ 200 lines
3. `cargo build -p zephyr` passes
4. `cargo test -p zephyr` passes
5. `cargo clippy -p zephyr -- -D warnings` passes
