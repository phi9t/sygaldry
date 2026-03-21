# RFC-019: Rust Dead Code Cleanup

**Status:** Proposed
**Priority:** Low
**Effort:** S
**Area:** rust-core
**Date:** 2026-03-21

## Problem

Nine `#[allow(dead_code)]` annotations across six files in
`crates/zephyr/src/` suppress compiler warnings for unused items. Keeping them
silently prevents the compiler from flagging real future dead code in those
modules.

## Evidence

Current list:

```text
crates/zephyr/src/error.rs:36              — SpackNotFound(PathBuf)
crates/zephyr/src/error.rs:46              — RepoNotFound(PathBuf)
crates/zephyr/src/error.rs:50              — InvalidConfig { ... }
crates/zephyr/src/context.rs:18            — RuntimeContext::is_container()
crates/zephyr/src/context.rs:23            — RuntimeContext::is_host()
crates/zephyr/src/container/cuda.rs:50     — detect_cuda_version()
crates/zephyr/src/container/entrypoint.rs:420 — exec_shell()
crates/zephyr/src/host/dirs.rs:51          — print_layout_summary()
crates/zephyr/src/host/lease.rs:7          — LeaseRecord
```

Several of these are entirely unreferenced outside their own definitions;
others are only referenced by tests or by code paths that no longer require the
suppression.

## Proposed Changes

1. Remove `SpackNotFound`, `RepoNotFound`, and `InvalidConfig` from `ZephyrError`
   if no concrete implementation plan requires them within the current
   milestone.
2. For `RuntimeContext::is_container()` and `RuntimeContext::is_host()`, either
   move them behind `#[cfg(test)]` or use them in production call paths so the
   suppression is no longer necessary.
3. For `detect_cuda_version()`, `exec_shell()`, `print_layout_summary()`, and
   `LeaseRecord`, remove the unused item if it has no active caller, or remove
   the stale `#[allow(dead_code)]` annotation if the item is already live.

## Files Changed

- `crates/zephyr/src/error.rs` — remove three unused variants
- `crates/zephyr/src/context.rs` — resolve the two test-only helper suppressions
- `crates/zephyr/src/container/cuda.rs` — resolve the stale CUDA-version helper suppression
- `crates/zephyr/src/container/entrypoint.rs` — resolve the stale `exec_shell()` suppression
- `crates/zephyr/src/host/dirs.rs` — resolve the layout-summary suppression
- `crates/zephyr/src/host/lease.rs` — resolve the unused `LeaseRecord` suppression

## Verification

```bash
cd crates/zephyr
cargo build 2>&1 | grep -c "dead_code"
# must be 0 once all suppressions are removed
cargo test
```
