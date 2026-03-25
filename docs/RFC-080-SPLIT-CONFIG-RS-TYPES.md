# RFC-080: Split config.rs Enums to config_types.rs

**Status:** Open
**Date:** 2026-03-25
**Priority:** Low
**Effort:** S

---

## Problem

`crates/zephyr/src/config.rs` is 976 lines. Lines 6–73 contain 4 pure enum
definitions and line 333 defines `SharedCaches` — all are pure data types with
no logic. They are buried in a large configuration module that also contains
builder logic, defaults, and CLI override handling.

Types to extract:
- `enum BuildPolicy` (line 6)
- `enum LeaseMode` (line 25)
- `enum CacheProfile` (line 44)
- `enum LaunchMode` (line 63)
- `struct SharedCaches` (line 333)

---

## Solution

Create `crates/zephyr/src/config_types.rs` with the 5 type definitions and
their `impl` blocks (each enum has a `parse()` method that must move with it).

**`crates/zephyr/src/config_types.rs` must contain:**
- `use std::path::PathBuf;` (required by `LaunchMode`)
- `pub enum BuildPolicy` + `impl BuildPolicy` (lines 6–21)
- `pub enum LeaseMode` + `impl LeaseMode` (lines 25–40)
- `pub enum CacheProfile` + `impl CacheProfile` (lines 44–59)
- `pub enum LaunchMode` (lines 63–66; no impl block)
- `pub(crate) struct SharedCaches` (lines 333–342; was `struct SharedCaches`, must
  stay at least `pub(crate)` so `config.rs` can use it after moving)

**`crates/zephyr/src/config.rs` changes:**
- Remove the 5 type definitions and their `impl` blocks.
- Add at the top (after existing `use` lines):
  ```rust
  pub use crate::config_types::{BuildPolicy, CacheProfile, LaunchMode, LeaseMode};
  use crate::config_types::SharedCaches;
  ```
  The `pub use` re-exports are required because `lease.rs`, `image.rs`, and
  `docker_args.rs` all import these types from `crate::config::` — those
  callers must NOT be changed.

**`crates/zephyr/src/main.rs` changes** (note: this is a binary crate — there is
no `lib.rs`):
- Add the module declaration after the existing `mod config;` line:
  ```rust
  mod config_types;
  ```

**Ordering:** Create `config_types.rs` first, then edit `config.rs` to add the
`pub use` lines and remove the inline definitions, then edit `main.rs` to add
`mod config_types;`.

---

## Acceptance Criteria

1. `crates/zephyr/src/config_types.rs` exists with all 5 type definitions
2. `config.rs` reduced to ≤ 910 lines
3. `cargo build -p zephyr` passes
4. `cargo test -p zephyr` passes
