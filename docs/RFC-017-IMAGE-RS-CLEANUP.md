# RFC-017: image.rs Production Visibility and Safety Cleanup

**Status:** Proposed
**File:** `crates/zephyr/src/host/image.rs`

---

## Problem

`crates/zephyr/src/host/image.rs` contains three issues that reduce production
reliability: the core build-decision logic is hidden under `#[cfg(test)]` and
thus never executes in production; unsafe `libc` calls lack safety comments; and
a timestamp fallback silently produces incorrect build decisions.

---

## Key Findings

### 1. `should_build_decision` is `#[cfg(test)]`-only

The function that encodes the complete build policy logic is decorated with
`#[cfg(test)]`:

```rust
// crates/zephyr/src/host/image.rs:44-75
/// Determine if we should build the image (pure logic, no side effects).
///
/// Returns `Ok(true)` to build, `Ok(false)` to skip, `Err` if Never policy + missing image.
#[cfg(test)]
fn should_build_decision(
    policy: BuildPolicy,
    img_exists: bool,
    df_mtime: Option<i64>,
    img_epoch: Option<i64>,
) -> Result<bool> {
    match policy {
        BuildPolicy::Never => {
            if !img_exists {
                return Err(ZephyrError::ImageNotFound {
                    image: "(policy=never)".to_string(),
                });
            }
            Ok(false)
        }
        BuildPolicy::Always => Ok(true),
        BuildPolicy::Auto => {
            if !img_exists {
                Ok(true)
            } else if let Some(df_mt) = df_mtime {
                let img_ts = img_epoch.unwrap_or(0);
                Ok(df_mt > img_ts)
            } else {
                Ok(false)
            }
        }
    }
}
```

The production `build_image` function (lines 78–161) duplicates this logic
inline rather than calling `should_build_decision`. The test suite exercises
`should_build_decision` in isolation (lines 179–228), but those tests have no
coverage of `build_image`'s inline copy. Any divergence between the two
implementations is invisible.

The `#[cfg(test)]` attribute was presumably added to make the function testable
as a pure function, but the correct approach is to make it production code and
call it from `build_image`.

### 2. Unsafe `libc` calls without safety comments

Lines 125–126 call `libc::getuid()` and `libc::getgid()` via `unsafe` blocks:

```rust
// crates/zephyr/src/host/image.rs:125-126
let uid = unsafe { libc::getuid() };
let gid = unsafe { libc::getgid() };
```

Rust's safety rules require that every `unsafe` block be accompanied by a
comment explaining the invariants that guarantee safety. Here, neither call
has a comment. `getuid` and `getgid` are always safe to call (they have no
preconditions and cannot invoke undefined behaviour), but the absence of a
comment leaves future readers uncertain about whether there is a hidden concern.

### 3. `image_created_epoch` silently uses `unwrap_or(0)` for timestamp

The production code in `build_image` at line 104:

```rust
// crates/zephyr/src/host/image.rs:98-104
let img_epoch = image_created_epoch(&config.image).unwrap_or(0);
df_mtime > img_epoch
```

When `image_created_epoch` returns `None` (Docker unavailable, parse failure,
or the image has no creation timestamp), the epoch falls back to `0`
(1970-01-01). Any Dockerfile with an mtime after epoch 0 — which is every file
on a live system — will trigger a rebuild. This is not logged; the user sees a
build start with no indication that the timestamp comparison is degenerate.

The `should_build_decision` function encodes the same fallback:

```rust
// crates/zephyr/src/host/image.rs:68
let img_ts = img_epoch.unwrap_or(0);
```

Both fallbacks are silent and produce potentially unexpected rebuilds.

---

## Proposed Changes

### 1. Promote `should_build_decision` to production code

Remove `#[cfg(test)]` from `should_build_decision` and make it `fn` (or `pub(crate) fn`).
Replace the inline match in `build_image` with a call to the extracted function:

```rust
// Proposed: build_image refactored
pub fn build_image(config: &ZephyrConfig, force: bool) -> Result<()> {
    let policy = if force { BuildPolicy::Always } else { config.build_policy };

    let dockerfile = config.sygaldry_home.join("container/dev_container.dockerfile");
    let img_exists = image_exists(&config.image);

    let df_mtime = dockerfile.exists().then(|| {
        std::fs::metadata(&dockerfile)
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
    }).flatten();

    let img_epoch = image_created_epoch(&config.image);

    let should_build = should_build_decision(policy, img_exists, df_mtime, img_epoch)?;

    if !should_build {
        return Ok(());
    }
    ...
}
```

The existing test suite for `should_build_decision` now covers the production
path.

### 2. Add safety comments to unsafe blocks

```rust
// SAFETY: getuid(2) and getgid(2) are always safe to call; they have no
// preconditions, do not dereference pointers, and cannot cause undefined
// behaviour.
let uid = unsafe { libc::getuid() };
let gid = unsafe { libc::getgid() };
```

### 3. Log when timestamp fallback is used

In `should_build_decision` (or at the call site in `build_image`), emit a
diagnostic when `img_epoch` is `None`:

```rust
BuildPolicy::Auto => {
    if !img_exists {
        Ok(true)
    } else if let Some(df_mt) = df_mtime {
        let img_ts = match img_epoch {
            Some(ts) => ts,
            None => {
                eprintln!(
                    "[zephyr] warning: could not determine image creation time for '{}', \
                     assuming rebuild needed",
                    // image name would be threaded in via a parameter or closure
                    "(image)"
                );
                0
            }
        };
        Ok(df_mt > img_ts)
    } else {
        Ok(false)
    }
}
```

To support diagnostic messages, `should_build_decision` can accept an optional
image name string for use in the warning, or the caller can log after receiving
`None` from `image_created_epoch`.

---

## Files Changed

| File | Action |
|------|--------|
| `crates/zephyr/src/host/image.rs` | Remove `#[cfg(test)]` from `should_build_decision`, call it from `build_image`, add safety comments, add timestamp fallback diagnostic |

---

## Verification

```bash
cd crates/zephyr
cargo build
cargo test
cargo clippy -- -D warnings
```

Confirm that `should_build_decision` is reachable from the production call graph
(e.g., `cargo rustdoc` should list it, or `cargo test -- --list` should not be
the only path that includes it).

The existing 8 tests for `should_build_decision` (lines 179–228) must continue
to pass without modification.
