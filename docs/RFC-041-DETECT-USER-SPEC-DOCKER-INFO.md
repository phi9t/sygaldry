# RFC-041: Cache detect_user_spec Result to Avoid docker info on Every Launch

**Status:** Proposed
**Priority:** Low
**Effort:** S
**Area:** rust-core

## Problem

`crates/zephyr/src/host/docker_args.rs` `detect_user_spec()` runs `docker info` on every container launch to detect whether Docker is running in rootless mode. `docker info` contacts the Docker daemon and typically takes 100–500ms. This adds latency to every `zephyr shell`, `zephyr run`, and `zephyr job` invocation.

For pipelines that launch many containers in sequence (e.g., a SAIL cycle that runs 3–8 agent tasks), this is a measurable overhead. The rootless mode of the Docker daemon does not change between launches, so re-querying it every time is unnecessary.

## Evidence

`crates/zephyr/src/host/docker_args.rs` `detect_user_spec()` function (~line 277):
```rust
let output = std::process::Command::new("docker")
    .args(["info", "--format", "{{.SecurityOptions}}"])
    .output()?;
// parses output to detect rootless
```

Called unconditionally from `build()` on every launch.

## Proposed Changes

1. Cache the result in a file at a well-known path, e.g., `~/.cache/zephyr/docker-rootless` (a boolean file whose existence means rootless, absence means non-rootless).

2. On startup, check if the cache file exists and is less than 24 hours old. If so, use the cached result. Otherwise, run `docker info` and write the result to the cache.

3. Honor `ZEPHYR_FORCE_DETECT_USER=1` to bypass the cache and force a fresh detection.

4. Alternatively (simpler): add a `ZEPHYR_ROOTLESS=0|1` env var that directly overrides detection, and document that users on rootless Docker should set `ZEPHYR_ROOTLESS=1`.

The simpler env-var approach is preferred for the initial implementation; the file cache can follow.

## Files Changed

- `crates/zephyr/src/host/docker_args.rs` — env var override for rootless detection
- `crates/zephyr/src/config.rs` — `rootless_override: Option<bool>` field
- `CLAUDE.md` — document `ZEPHYR_ROOTLESS` env var

## Verification

```bash
cd crates/zephyr && cargo test
# Time two launches and verify the second is faster when cache is warm:
time cargo run -- shell --dry-run
time cargo run -- shell --dry-run
```
