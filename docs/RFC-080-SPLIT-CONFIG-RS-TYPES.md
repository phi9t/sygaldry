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

Create `crates/zephyr/src/config_types.rs` with the 5 type definitions.

In `crates/zephyr/src/config.rs`, replace the inline definitions with:
```rust
use crate::config_types::{BuildPolicy, LeaseMode, CacheProfile, LaunchMode, SharedCaches};
```

In `crates/zephyr/src/lib.rs`, add:
```rust
pub mod config_types;
```

---

## Acceptance Criteria

1. `crates/zephyr/src/config_types.rs` exists with all 5 type definitions
2. `config.rs` reduced to ≤ 910 lines
3. `cargo build -p zephyr` passes
4. `cargo test -p zephyr` passes
