# RFC-006: Rust Entrypoint Consolidation

**Status:** Draft — v1
**Date:** 2026-03-16
**Priority:** High — prerequisite for RFC-002 Phase 3 (deleting bash entrypoints)

---

## 1. Problem

The Rust container entrypoint system (`container/entrypoint.rs`) is complete but the launcher never uses it. The Rust launcher still dispatches to bash scripts.

### Current dispatch chain

```
sygaldry shell
  → zephyr shell (Rust)
  → host/launcher.rs::launch()
  → resolve_entrypoint_dir()         ← validates bash script existence on host
  → docker_args::build()
  → docker_args::resolve_entrypoint_path()  ← returns bash script container path
  → docker run ... <image> /workspace/container/entrypoints/default.sh
                                     ↑ BASH script runs inside container
```

### What should happen

```
sygaldry shell
  → zephyr shell (Rust)
  → host/launcher.rs::launch()
  → docker run --entrypoint zephyr <image> entrypoint default
                                   ↑ RUST binary runs inside container
                                     → container/entrypoint.rs::run("default", args)
```

### Why this matters

`host/launcher.rs:77-104` — `resolve_entrypoint_dir()` currently:

1. Checks if image label `sygaldry.entrypoints.baked == "true"` → returns baked dir
2. Checks if image label `sygaldry.spack.baked == "true"` → returns spack baked dir
3. Falls back: validates `container/entrypoints/{name}.sh` **exists on host**

Path 3 means bash scripts are a hard runtime dependency. If they're deleted, `zephyr shell` errors with `EntrypointNotFound`.

`host/docker_args.rs:21-44` — `resolve_entrypoint_path()` always returns a `.sh` path. There is no code path that emits `entrypoint default` as the container CMD.

---

## 2. Design

Add a new entrypoint dispatch mode: **Rust-native mode**. When the image has `zephyr` on `PATH`, the launcher uses `--entrypoint zephyr` and passes `entrypoint <name> [args...]` as the container CMD.

### Detection

The image has Rust entrypoints available if:
- Label `sygaldry.zephyr.version` is set (any value), OR
- Label `sygaldry.entrypoints.baked == "true"` is set

Check via `docker inspect`:
```rust
fn image_has_rust_entrypoints(image: &str) -> bool {
    image::read_image_label(image, "sygaldry.zephyr.version").is_some()
    || image::read_image_label(image, "sygaldry.entrypoints.baked").as_deref() == Some("true")
}
```

For development (image not yet labeled), add env var escape hatch:
```rust
// ZEPHYR_USE_RUST_ENTRYPOINTS=1 forces Rust mode for testing
if std::env::var("ZEPHYR_USE_RUST_ENTRYPOINTS").as_deref() == Ok("1") {
    return true;
}
```

### Launcher change (`host/launcher.rs`)

```rust
// In launch():
let use_rust_entrypoints = image_has_rust_entrypoints(&config.image)
    || std::env::var("ZEPHYR_USE_RUST_ENTRYPOINTS").as_deref() == Ok("1");

let cmd_args = if use_rust_entrypoints {
    docker_args::build_rust_mode(config, entrypoint_name, spack_baked)?
} else {
    // Legacy bash mode — existing code path, unchanged
    let entrypoint_container_dir = resolve_entrypoint_dir(...)?;
    docker_args::build(config, entrypoint_name, spack_baked, entrypoint_container_dir.as_deref())?
};
```

Remove the bash file existence check from `resolve_entrypoint_dir` entirely — it's only needed in bash mode, and bash mode will be removed in RFC-002 Phase 5.

### Docker args change (`host/docker_args.rs`)

New function `build_rust_mode`:
```rust
pub(crate) fn build_rust_mode(
    config: &ZephyrConfig,
    entrypoint_name: &str,
    spack_baked: bool,
) -> crate::error::Result<Vec<String>> {
    let mut args = build_common_flags(config)?;
    build_volume_mounts(&mut args, config, spack_baked)?;
    build_mode_mounts(&mut args, config, None)?;
    build_env_args(config, ...);

    // Override docker entrypoint to use Rust binary
    args.push("--entrypoint".into());
    args.push("zephyr".into());

    // Container CMD: entrypoint <name> [passthrough args added by caller]
    // The image field + entrypoint <name> args are appended by launcher.rs
    Ok(args)
}
```

In `launcher.rs::launch()`, the final docker command becomes:
```rust
// Rust mode:
// docker run [common args] --entrypoint zephyr <image> entrypoint <name> [passthrough...]
cmd_args.push(config.image.clone());
cmd_args.push("entrypoint".into());
cmd_args.push(entrypoint_name.into());
cmd_args.extend_from_slice(passthrough_args);
```

---

## 3. Dockerfile change

Add the `sygaldry.zephyr.version` label to `container/dev_container.dockerfile`:

```dockerfile
# Near the end of the Dockerfile, after the zephyr binary is installed:
LABEL sygaldry.zephyr.version="1.0"
LABEL sygaldry.entrypoints.baked="true"
```

This enables automatic Rust entrypoint detection without requiring the env var escape hatch.

Ensure `zephyr` is on `PATH` in the image:
```dockerfile
# Install zephyr binary (already done via Spack view or explicit COPY)
COPY --from=builder /build/target/release/zephyr /usr/local/bin/zephyr
```

If the image is not built fresh (using the spack snapshot), the env var `ZEPHYR_USE_RUST_ENTRYPOINTS=1` can be passed to force Rust mode without the label.

---

## 4. Backward Compatibility

The legacy bash mode is preserved: if the image has neither label nor env var, `resolve_entrypoint_dir` falls back to the existing bash path. This ensures the transition is non-breaking for existing images.

Bash mode will be removed in RFC-002 Phase 5, once all images carry the Rust label.

---

## 5. Files Changed

| File | Action |
|------|--------|
| `crates/zephyr/src/host/launcher.rs` | Add `image_has_rust_entrypoints()`, conditional dispatch |
| `crates/zephyr/src/host/docker_args.rs` | Add `build_rust_mode()` function |
| `container/dev_container.dockerfile` | Add `sygaldry.zephyr.version` and `sygaldry.entrypoints.baked` labels |

---

## 6. Verification

```bash
# Unit tests
cargo test -p zephyr

# Rust entrypoint smoke test (requires built binary in image)
ZEPHYR_USE_RUST_ENTRYPOINTS=1 sygaldry run -- echo hello
# → should run via: docker run --entrypoint zephyr ... entrypoint run-job echo hello
# → container/entrypoint.rs::run("run-job", ["echo", "hello"]) executes

# Verify bash scripts are NOT called
ZEPHYR_USE_RUST_ENTRYPOINTS=1 strace -e execve sygaldry shell 2>&1 | grep "entrypoints"
# Expected: no /workspace/container/entrypoints/ in exec calls
```

---

## 7. Dependency on Other RFCs

- **RFC-002** depends on RFC-006: RFC-002 Phase 3 (delete bash entrypoints) can only proceed after RFC-006 is merged and verified.
- **RFC-006** is self-contained and can be merged independently.

## 8. Risk Register

| Risk | Severity | Mitigation |
|------|----------|-----------|
| `zephyr` not on `PATH` in container | High | Dockerfile COPY + check in `requirements::check_all()` |
| Image label not set on old snapshots | Medium | Env var override `ZEPHYR_USE_RUST_ENTRYPOINTS=1` |
| Entrypoint behavior differs from bash | Medium | All 9 entrypoints have Rust implementations; smoke test each |
| Non-interactive shells behave differently | Low | `entrypoint_default` calls same `full_init()` + GPU check as `default.sh` |
