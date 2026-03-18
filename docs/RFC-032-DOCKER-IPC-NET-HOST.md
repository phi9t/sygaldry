# RFC-032: Reduce --ipc=host and --net=host Exposure

**Status:** Proposed
**Priority:** Medium
**Effort:** M
**Area:** docker

## Problem

The container launcher passes `--ipc=host` and `--net=host` to `docker run`. These flags grant the container access to the host IPC namespace and all host network interfaces respectively.

- `--ipc=host`: Allows the container to read and write shared memory segments owned by host processes. A compromised container can attach to any host IPC resource.
- `--net=host`: Exposes all host network interfaces to the container. The container can bind to any host port, sniff host network traffic, and bypass container network isolation entirely.

For GPU workloads, neither flag is strictly required by NVIDIA drivers with CUDA 12.x. NCCL distributed training needs high-bandwidth inter-process communication but can use `--ipc=host` only when `SHM_SIZE` is insufficient — this should be opt-in, not the default.

## Evidence

`container/launch_container.sh` (and equivalent in `crates/zephyr/src/host/docker_args.rs`):
```bash
DOCKER_ARGS+=("--ipc=host")
DOCKER_ARGS+=("--net=host")
```

These flags appear unconditionally in both the bash launcher and the Rust `build()` function.

## Proposed Changes

1. **Networking**: Replace `--net=host` with `--network=bridge` (Docker default). Bridge networking provides container isolation while still allowing outbound internet access. Add a `ZEPHYR_NET_HOST=1` env var opt-in for cases that genuinely require host networking (e.g., certain NCCL configurations).

2. **IPC**: Replace `--ipc=host` with `--ipc=shareable` + `--shm-size=16g` (configurable via `ZEPHYR_SHM_SIZE`). This provides the large shared memory that PyTorch DataLoader workers need without full host IPC access.

3. Existing `--shm-size` logic in the launcher should be reviewed and unified with the new default.

4. Document the `ZEPHYR_NET_HOST` and `ZEPHYR_SHM_SIZE` env vars.

## Files Changed

- `crates/zephyr/src/host/docker_args.rs` — change IPC and network defaults
- `container/launch_container.sh` — same
- `CLAUDE.md` — document new env vars

## Verification

```bash
# GPU test must still pass after the change:
./container/launch_container.sh --entrypoint verify-gpu.sh
# NCCL test with bridge networking (requires multi-GPU host):
# NCCL_DEBUG=INFO python -c "import torch.distributed; ..."
```
