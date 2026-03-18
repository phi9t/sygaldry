# RFC-040: Replace build_shared_caches 8-Tuple Return with a Struct

**Status:** Proposed
**Priority:** Low
**Effort:** XS
**Area:** rust-core

## Problem

`crates/zephyr/src/config.rs` `build_shared_caches()` returns an 8-tuple of `PathBuf` values. Positional tuple destructuring is error-prone: swapping two `PathBuf` values at the call site silently compiles. Adding a ninth cache directory requires updating every call site.

## Evidence

`crates/zephyr/src/config.rs` — approximate signature:
```rust
fn build_shared_caches(root: &Path) -> (PathBuf, PathBuf, PathBuf, PathBuf, PathBuf, PathBuf, PathBuf, PathBuf) {
    (
        root.join("spack_store"),
        root.join("hf_cache"),
        root.join("uv_cache"),
        root.join("bazel_cache"),
        root.join("workspace"),
        // ... etc.
    )
}
```

Call site in `build_paths()`:
```rust
let (spack_store, hf_cache, uv_cache, bazel_cache, workspace, ...) = build_shared_caches(&root);
```

## Proposed Changes

1. Define a `SharedCaches` struct:
   ```rust
   pub struct SharedCaches {
       pub spack_store: PathBuf,
       pub hf_cache:    PathBuf,
       pub uv_cache:    PathBuf,
       pub bazel_cache: PathBuf,
       pub workspace:   PathBuf,
       // add new fields here without breaking callers
   }
   ```

2. Change `build_shared_caches()` to return `SharedCaches`.

3. Update all call sites to use field access instead of positional destructuring.

This is a pure refactor with no behaviour change.

## Files Changed

- `crates/zephyr/src/config.rs` — new `SharedCaches` struct, updated `build_shared_caches()` and all call sites

## Verification

```bash
cd crates/zephyr && cargo build && cargo test
# Must compile with zero warnings after removing any now-unused tuple bindings.
```
