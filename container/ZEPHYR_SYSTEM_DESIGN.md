# Zephyr Container Infra: Engineering System Design

**Version:** 1.1
**Date:** 2026-01-28
**Status:** Current Implementation

---

## Executive Summary

The Zephyr container infrastructure provides a reproducible, GPU-enabled AI/ML development environment built on Docker + Spack. The system standardizes CUDA 12.9.1 tooling, persists build artifacts on shared host storage, and supports long-running Spack builds with durable logging. The container image embeds Spack v1.1.0, while the environment definition lives in `pkg/zephyr/`.

---

## Goals

- Reproducible CUDA 12.9.1 development environment
- Persistent Spack artifacts across container runs
- Host/shared storage for large build outputs
- Simple, robust long-build logging and monitoring
- Entry point dispatch for different workflows
- Human ergonomics: one-line commands for Spack/uv/HF workflows
- Agent ergonomics: structured logs + status for low-token monitoring

## Non-Goals

- CI/CD orchestration (handled externally)
- Package pinning across all deps beyond Spack defaults
- Multi-arch image support

---

## Architecture Overview

```
Host System
  /mnt/data_infra/zephyr_container_infra/<project_id>/
    monorepo_home/   -> /home/kvothe
    spack_store/     -> /opt/spack_store
    bazel_cache/     -> /opt/bazel_cache
    config/

Docker Image: sygaldry/zephyr:base
  Base: nvidia/cuda:12.9.1-cudnn-devel-ubuntu24.04
  Spack: /opt/spack_src (v1.1.0)

Workspace Mount
  /mnt/data_infra/workspace/sygaldry -> /workspace
```

### Key Components

- **Container image**: `sygaldry/zephyr:base`
  - CUDA 12.9.1 + cuDNN
  - Spack v1.1.0 embedded at `/opt/spack_src`
  - Build tooling (Bazel, Go, LLVM toolchain, etc.)

- **Launcher**: `container/launch_container.sh`
  - Mounts shared host storage
  - Supports entrypoint dispatch
  - Optional GPU enablement via `SYGALDRY_GPU`

- **Spack env**: `pkg/zephyr/`
  - `spack_src.yaml` defines the Zephyr AI/ML stack
  - `build.sh` builds into `/opt/spack_store`

- **Entrypoints**: `container/entrypoints/*.sh`
  - `default.sh` (interactive or run command)
  - `spack-install.sh` (runs `spack install` then shell)
  - `spack-build.sh` (runs Zephyr build script)
  - `uv-install.sh` (runs `uv venv` + `uv pip install`)
  - `hf-download.sh` (downloads HF dataset to shared cache)
  - `run-job.sh` (generic command runner)

---

## Storage and Persistence

Shared host storage (project-scoped):

- **Root**: `/mnt/data_infra/zephyr_container_infra/<project_id>`
- **Spack store**: `/opt/spack_store`
- **Bazel cache**: `/opt/bazel_cache`
- **Home**: `/home/kvothe`

This allows:
- Reuse of Spack install artifacts
- Shorter rebuilds
- Stable user home across container runs

---

## Build Flow

1. Build/launch container:
   - `./container/launch_container.sh`
2. Build Zephyr Spack env inside container:
   - `cd /workspace/pkg/zephyr && ./build.sh`
3. Spack installs into `/opt/spack_store`

### Human-Oriented Shortcuts

- `SYGALDRY_ENTRYPOINT=spack-build ./container/launch_container.sh`
- `SYGALDRY_ENTRYPOINT=uv-install ./container/launch_container.sh -- <packages...>`
- `SYGALDRY_ENTRYPOINT=hf-download ./container/launch_container.sh -- <dataset> <config> <split>`

### Agent-Oriented Job Runner

- **Runner**: `tools/zephyr_job`
- **Status**: `/mnt/data_infra/zephyr_container_infra/<project_id>/bazel_cache/zephyr_jobs/<job>.status`
- **Logs**: `/mnt/data_infra/zephyr_container_infra/<project_id>/bazel_cache/zephyr_jobs/<job>-<timestamp>.jsonl`

### Long Build Logging (Recommended)

```
LOG=/mnt/data_infra/zephyr_container_infra/build_logs/zephyr-build-$(date +%Y%m%d-%H%M%S).log
mkdir -p "$(dirname "$LOG")"
./container/launch_container.sh -- bash -lc "cd /workspace/pkg/zephyr && ./build.sh" 2>&1 | tee "$LOG"
```

Monitor in another terminal:

```
tail -f "$LOG"
```

---

## CUDA Compatibility

- Container CUDA: **12.9.1**
- Host driver must support CUDA >= 12.9

The launcher can auto-disable GPU if the host CUDA version is too low.

---

## Spack Environment Notes

`pkg/zephyr/spack_src.yaml` includes:
- PyTorch with CUDA (`py-torch+cuda cuda_arch=61,75,80,86,89,90`)
- JAX runtime with CUDA (`py-jaxlib+cuda cuda_arch=61,75,80,86,89,90`)
- Standard data-science stack (numpy, scipy, pandas, matplotlib, jupyterlab)

---

## Observability

- **Job logs**: `/mnt/data_infra/zephyr_container_infra/<project_id>/bazel_cache/zephyr_jobs/`
- **Status files**: `/mnt/data_infra/zephyr_container_infra/<project_id>/bazel_cache/zephyr_jobs/`
- **Container logs**: `docker logs <container_id>`

---

## Failure Modes and Mitigations

- **CUDA mismatch**: update host driver or use older CUDA image
- **Spack variant mismatch**: adjust `spack_src.yaml` to match supported variants
- **Long build times**: use logging + persistent storage to allow restart

---

## Future Improvements

- Add build-cache mirrors for faster Spack installs
- Add a Make target to manage long build logs
- Add CI verification of CUDA Torch/JAX runtime
