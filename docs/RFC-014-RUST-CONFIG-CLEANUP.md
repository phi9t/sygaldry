# RFC-014: Rust Config and Paths Cleanup

**Status:** Proposed
**Files:** `crates/zephyr/src/config.rs`, `crates/zephyr/src/paths.rs`

---

## Problem

`config.rs` (723 lines) and `paths.rs` (305 lines) contain several code quality
issues: a function returning an 8-element tuple, duplicated path-construction
patterns, a dead struct field suppressed with `#[allow(dead_code)]`, and a
hardcoded JSON string in a library function.

---

## Key Findings

### 1. `build_shared_caches` returns a large positional tuple

`build_shared_caches` at `config.rs:264-302` returns an 8-tuple of `PathBuf`:

```rust
// crates/zephyr/src/config.rs:264-267
fn build_shared_caches(
    build_root: &PathBuf,
    shared_root: &PathBuf,
) -> (PathBuf, PathBuf, PathBuf, PathBuf, PathBuf, PathBuf, PathBuf, PathBuf) {
```

The caller destructures it by positional index (lines 252–259):

```rust
// crates/zephyr/src/config.rs:252-259
let shared_caches = build_shared_caches(&build_root, &shared_root);

HostLayout {
    ...
    spack_store: shared_caches.0,
    bazel_cache: shared_caches.1,
    hf_cache: shared_caches.2,
    uv_cache: shared_caches.3,
    torch_cache: shared_caches.4,
    triton_cache: shared_caches.5,
    nv_compute_cache: shared_caches.6,
    jax_cache: shared_caches.7,
}
```

Positional tuple fields have no names; adding or reordering a cache requires
updating both the function signature and every call site by index. This is
fragile and hard to read.

### 2. Duplicated path construction pattern

The same pattern — `env_or("VAR", &some_root.join("subdir").display().to_string())` —
appears 6 times in `build_host_layout` (lines 222–233) and 8 times in
`build_shared_caches` (lines 268–299). Each invocation constructs a temporary
`String` from a `PathBuf` display to satisfy the `&str` API of `env_or`.

A helper that accepts a `PathBuf` default directly would eliminate the
`.display().to_string()` noise:

```rust
fn path_from_env_or(var: &str, default: PathBuf) -> PathBuf {
    std::env::var(var)
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or(default)
}
```

### 3. `#[allow(dead_code)]` on `projects_root`

`paths.rs:51-52`:

```rust
// crates/zephyr/src/paths.rs:51-52
#[allow(dead_code)]
pub projects_root: PathBuf,
```

`projects_root` is populated in `build_host_layout` (config.rs:228) and stored
in `HostLayout` but never read. The `#[allow(dead_code)]` is a suppressed
warning rather than a fix. Either the field should be used (e.g., exposed in
`print_effective`) or removed.

The test at `paths.rs:257` confirms it is populated but tests only that the
returned layout has the expected directory count — it does not assert any read
path that would exercise `projects_root`.

### 4. Hardcoded JSON in `write_layout_version`

`paths.rs:113-117`:

```rust
// crates/zephyr/src/paths.rs:113-117
pub fn write_layout_version(&self) -> crate::error::Result<()> {
    let path = self.meta_root.join("layout_version.json");
    let content =
        r#"{"layout_version":2,"layout_name":"unified-shared-cache-project-isolation"}"#;
    std::fs::write(&path, content.as_bytes()).with_path(&path)?;
    Ok(())
}
```

The layout version integer `2` and the layout name string are embedded as
literals inside a raw JSON string. If either value needs changing, the string
must be edited carefully to avoid producing invalid JSON. Extracting them as
named constants makes the intent explicit:

```rust
const LAYOUT_VERSION: u32 = 2;
const LAYOUT_NAME: &str = "unified-shared-cache-project-isolation";
```

---

## Proposed Changes

### 1. Replace the 8-tuple with a named struct

```rust
struct SharedCaches {
    spack_store: PathBuf,
    bazel_cache: PathBuf,
    hf_cache: PathBuf,
    uv_cache: PathBuf,
    torch_cache: PathBuf,
    triton_cache: PathBuf,
    nv_compute_cache: PathBuf,
    jax_cache: PathBuf,
}
```

`build_shared_caches` returns `SharedCaches`. The caller spreads it into
`HostLayout` fields by name. Adding a ninth cache requires no change to
positional indexing.

### 2. Extract `path_from_env_or` helper

Replace all `PathBuf::from(env_or("VAR", &root.join("sub").display().to_string()))`
calls with `path_from_env_or("VAR", root.join("sub"))`.

### 3. Remove `projects_root` or promote it

Option A: Remove `projects_root` from `HostLayout` and from `build_host_layout`.
The value is derivable as `projects_root.join(project_id)` wherever it is
needed.

Option B: Keep the field and expose it in `print_effective` so the
`#[allow(dead_code)]` is no longer needed.

Option A is preferred as it removes a field that currently serves no caller.

### 4. Extract constants in `write_layout_version`

```rust
const LAYOUT_VERSION: u32 = 2;
const LAYOUT_NAME: &str = "unified-shared-cache-project-isolation";

pub fn write_layout_version(&self) -> crate::error::Result<()> {
    let path = self.meta_root.join("layout_version.json");
    let content = format!(
        r#"{{"layout_version":{LAYOUT_VERSION},"layout_name":"{LAYOUT_NAME}"}}"#
    );
    std::fs::write(&path, content.as_bytes()).with_path(&path)?;
    Ok(())
}
```

---

## Files Changed

| File | Action |
|------|--------|
| `crates/zephyr/src/config.rs` | Replace tuple return with `SharedCaches` struct, extract `path_from_env_or` helper |
| `crates/zephyr/src/paths.rs` | Remove `projects_root` or promote it, extract layout version constants |

---

## Verification

```bash
cd crates/zephyr
cargo build
cargo test
cargo clippy -- -D warnings
```

All existing tests must pass; no new `#[allow(...)]` attributes should be
required.
