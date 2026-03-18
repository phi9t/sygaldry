# RFC-019: Rust Dead Code Cleanup

**Status:** Proposed
**Priority:** Low
**Effort:** XS
**Area:** rust-core

## Problem

Four items in the Rust crate carry `#[allow(dead_code)]` attributes, indicating they were added speculatively or became orphaned. Keeping them suppresses the compiler's ability to catch real future dead code in those modules.

## Evidence

`crates/zephyr/src/error.rs` lines 36-42:
```rust
#[allow(dead_code)]
#[error("Spack setup not found at {0}")]
SpackNotFound(PathBuf),

#[allow(dead_code)]
#[error("Repository not found at {0}")]
RepoNotFound(PathBuf),

#[allow(dead_code)]
#[error("Invalid configuration: {0}")]
InvalidConfig(String),
```

`crates/zephyr/src/paths.rs` line 52:
```rust
#[allow(dead_code)]
pub projects_root: PathBuf,
```

None of these are referenced anywhere in production call paths. A `grep -r "SpackNotFound\|RepoNotFound\|InvalidConfig\|projects_root"` across `crates/` yields zero non-definition matches.

## Proposed Changes

1. Remove `SpackNotFound`, `RepoNotFound`, and `InvalidConfig` from `ZephyrError` if no implementation plans require them within the next milestone.
2. Remove `projects_root` from `HostLayout` and its construction in `config.rs` `build_paths()`.
3. If any variant is genuinely planned, replace `#[allow(dead_code)]` with a `// TODO(RFC-NNN): needed for X` comment and file a concrete tracking issue instead.

## Files Changed

- `crates/zephyr/src/error.rs` — remove three unused variants
- `crates/zephyr/src/paths.rs` — remove `projects_root` field
- `crates/zephyr/src/config.rs` — remove `projects_root` assignment in `build_paths()`

## Verification

```bash
cd crates/zephyr && cargo build 2>&1 | grep -c "dead_code"
# must be 0
cargo test
```
