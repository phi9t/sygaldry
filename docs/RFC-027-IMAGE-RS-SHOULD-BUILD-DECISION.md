# RFC-027: Extract should_build_decision from cfg(test) into Production Code

**Status:** Proposed
**Priority:** Medium
**Effort:** S
**Area:** rust-core

## Problem

`crates/zephyr/src/host/image.rs` has a `should_build_decision()` function gated behind `#[cfg(test)]`. The production function `build_image()` contains a verbatim copy of the same branching logic. This means:

1. The production path is untestable in isolation — tests call `should_build_decision()` but production calls `build_image()` which may silently diverge.
2. Any future change to build-policy logic must be made in two places.

## Evidence

`crates/zephyr/src/host/image.rs`:
- Lines ~47-80: `#[cfg(test)]` block containing `should_build_decision(build_policy, image_exists)`.
- Lines ~84-110: `build_image()` production function with duplicated `match build_policy` branching.

The two are structurally identical: both return `true` for `BuildPolicy::Always`, `false` for `BuildPolicy::Never`, and `!image_exists` for `BuildPolicy::IfMissing`. Because the test function is under `#[cfg(test)]`, cargo strips it from the release binary, so there is zero guarantee they remain in sync.

## Proposed Changes

1. Move `should_build_decision()` outside the `#[cfg(test)]` block — make it a `pub(crate)` function in the module.
2. In `build_image()`, replace the inline match with a call to `should_build_decision()`:
   ```rust
   if !should_build_decision(build_policy, image_already_exists(&image_tag)?) {
       return Ok(());
   }
   ```
3. Keep the existing unit tests unchanged — they now test the authoritative production function.

## Files Changed

- `crates/zephyr/src/host/image.rs` — promote `should_build_decision` to `pub(crate)`, call it from `build_image()`

## Verification

```bash
cd crates/zephyr && cargo test
# The existing tests for should_build_decision must still pass.
# Confirm build_image() calls should_build_decision():
grep -n "should_build_decision" src/host/image.rs
```
