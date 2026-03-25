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

Extract into two new sibling files:

**`crates/zephyr/src/host/docker_env.rs`:**
- `build_env_args` and any env-only helpers it uses

**`crates/zephyr/src/host/docker_mounts.rs`:**
- `push_mount`, `build_volume_mounts`, `build_mode_mounts` and mount-only helpers

**`docker_args.rs` retains:**
- `build`, `build_rust_mode`, `detect_user_spec`, `dev_sudo_enabled`, `atty_stdin`
- `use super::docker_env::build_env_args;`
- `use super::docker_mounts::{build_volume_mounts, build_mode_mounts};`

**`crates/zephyr/src/host/mod.rs`:** add `pub mod docker_env; pub mod docker_mounts;`

Move the corresponding test sections into each new file's `#[cfg(test)]` block.

---

## Acceptance Criteria

1. `crates/zephyr/src/host/docker_env.rs` and `docker_mounts.rs` both exist
2. `docker_args.rs` reduced to ≤ 200 lines
3. `cargo build -p zephyr` passes
4. `cargo test -p zephyr` passes
5. `cargo clippy -p zephyr -- -D warnings` passes
