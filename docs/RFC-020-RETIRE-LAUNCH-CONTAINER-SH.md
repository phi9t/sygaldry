# RFC-020: Retire launch_container.sh — Delegate to Rust Binary

**Status:** Proposed
**Priority:** High
**Effort:** M
**Area:** shell / rust-core

## Problem

`container/launch_container.sh` is a ~550-line bash script that reimplements nearly everything the `crates/zephyr/` Rust binary already does:

- CUDA / NVIDIA runtime check
- Host directory setup (spack_store, hf_cache, uv_cache, bazel_cache, workspace)
- Docker args construction (GPU flags, volume mounts, env vars, user spec)
- Build-policy logic (always / if-missing / never)
- Lease management (flock-based)
- Entrypoint resolution

Running both in parallel means any bug fix or feature in one must be ported to the other. The bash script is the source of the `PYTHON_VERSION=3.12` default while the Rust binary defaults to `3.13` — a live discrepancy that affects container builds.

## Evidence

`container/launch_container.sh` line 76:
```bash
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
```

`crates/zephyr/src/config.rs` line 164:
```rust
python_version: env_or("PYTHON_VERSION", "3.13"),
```

`build_docker_args()` in the bash script: ~140 lines (lines 351–493).
`docker_args::build()` in Rust: equivalent functionality in `crates/zephyr/src/host/docker_args.rs`.

`build_container_image()` in bash: lines 223–281.
`image::build_image()` in Rust: `crates/zephyr/src/host/image.rs`.

`ContainerJob` Temporal activity (`temporal/internal/activities/steps.go`) calls `launch_container.sh` via `resolveContainerLauncherPath()`.

## Proposed Changes

1. **Fix the PYTHON_VERSION discrepancy immediately** (make both agree on `3.13`).
2. Thin `launch_container.sh` to a shim that delegates to the `zephyr` binary:
   ```bash
   #!/usr/bin/env bash
   # Compatibility shim — delegates to the zephyr Rust binary.
   exec "$(dirname "$0")/../target/release/zephyr" "$@"
   ```
3. Update `resolveContainerLauncherPath()` in `temporal/internal/activities/steps.go` to prefer the `zephyr` binary path directly, falling back to the shim only if the binary is absent.
4. Add a deprecation notice to `container/launch_container.sh` header.
5. Remove `launch_container.sh` entirely once all callers are verified to use the Rust binary (tracked as a follow-on commit).

## Files Changed

- `container/launch_container.sh` — replace with thin shim
- `crates/zephyr/src/config.rs` — ensure PYTHON_VERSION default is `"3.13"`
- `temporal/internal/activities/steps.go` — `resolveContainerLauncherPath()` prefers `zephyr` binary
- `CLAUDE.md` — update Quick Start to reference `zephyr` CLI, not the shell script

## Verification

```bash
# Build the Rust binary
cd crates/zephyr && cargo build --release

# Verify the shim delegates correctly
container/launch_container.sh --help | head -5

# Verify ContainerJob activity uses zephyr binary path
grep -n "resolveContainerLauncherPath\|launch_container" \
  temporal/internal/activities/steps.go

# Temporal integration
cd temporal && go test ./internal/activities/...
```
