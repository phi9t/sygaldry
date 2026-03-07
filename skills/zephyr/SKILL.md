---
name: zephyr
description: Run GPU container jobs with Spack (PyTorch/JAX), build and validate MLSys UV
  overlay environments, and vendor hermetic Zephyr runtime kits into target repos.
---

# Zephyr Skill

## Overview

The Zephyr skill provides two operating modes:

**Mode A — Direct usage from the sygaldry repo.** Use `container/launch_container.sh` to
launch the Docker container backed by the shared Spack store (PyTorch, JAX, CUDA).

**Mode B — Vendored kit in a target repo.** After running `zephyr_mlsys_vendor.sh install`,
the target repo gains a `.zephyr-mlsys/` directory with a self-contained `launch-mlsys.sh`
launcher and pre-built UV overlay environments for common MLSys profiles
(hf-transformers, vllm, hf-datasets).

The snapshot image (`ghcr.io/phi9t/sygaldry/zephyr:spack@sha256:8c9507aea53995f29a5712c0cbdb99deb3d571fb9631b3d42352b3d6d6fb668c`)
is the single hermetic baseline for both modes.

---

## Prerequisites

- NVIDIA Docker runtime installed and configured (`nvidia-ctk runtime configure --runtime=docker`)
- Docker installed and running
- CUDA 12.9.1 host driver (or compatible)
- Snapshot image available locally or pullable from `ghcr.io`

---

## Mode A: Direct usage (from sygaldry repo)

```bash
# Interactive shell (builds image if needed)
./container/launch_container.sh

# Run a command inside the container
./container/launch_container.sh -- python train.py

# Multi-repo mode: mount an external repo
./container/launch_container.sh --repo /path/to/my-project -- python train.py

# Run with a named entrypoint
./container/launch_container.sh --entrypoint verify-gpu.sh

# Download a HuggingFace model
./container/launch_container.sh --entrypoint hf-download.sh -- model Qwen/Qwen3-0.6B-Base
```

**Key flags:**

| Flag | Purpose |
|------|---------|
| `--repo <path>` | Mount external repo at `/workspace/<repo_name>` |
| `--entrypoint <name>` | Use a named entrypoint from `container/entrypoints/` |
| `--run-id <id>` | Set a unique run identifier for log isolation |
| `--lease-mode` | Enable lease-based container lifecycle management |
| `--print-effective-config` | Print resolved env/mount config and exit |

---

## Mode B: Vendored kit (target repo has `.zephyr-mlsys/`)

**Install into a target repo:**

```bash
skills/zephyr/scripts/zephyr_mlsys_vendor.sh install \
    --target-repo /path/to/target-repo \
    --snapshot-ref ghcr.io/phi9t/sygaldry/zephyr:spack@sha256:8c9507aea53995f29a5712c0cbdb99deb3d571fb9631b3d42352b3d6d6fb668c
```

**Launch MLSys profiles from the vendored kit:**

```bash
# HuggingFace Transformers (GPU)
.zephyr-mlsys/bin/launch-mlsys.sh hf-transformers

# vLLM serving (GPU)
.zephyr-mlsys/bin/launch-mlsys.sh vllm

# HuggingFace Datasets (CPU-only, skip GPU validation)
MLSYS_DISABLE_GPU=1 .zephyr-mlsys/bin/launch-mlsys.sh hf-datasets --no-validate
```

---

## Job execution (host-side)

The `tools/zephyr_job` CLI manages container jobs from the host:

```bash
tools/zephyr_job run    --project-id <id> --job <name> -- <command>
tools/zephyr_job status --project-id <id> --job <name>
tools/zephyr_job tail   --project-id <id> --job <name> [--lines N]
tools/zephyr_job stop   --project-id <id> --job <name>
tools/zephyr_job health --project-id <id> --job <name>
```

Jobs produce JSONL logs and status files under `/mnt/data_infra/zephyr_container_infra/<id>/`.

---

## Validation

```bash
repoctl verify image        --repo <path>
repoctl verify spack        --repo <path>
repoctl verify uv-layering  --repo <path>
```

Quick GPU checks inside the container:

```bash
./container/launch_container.sh --entrypoint verify-gpu.sh   # PyTorch + JAX
./container/launch_container.sh --entrypoint verify-spack.sh # Fast Spack only
```

---

## Burn-in

Run repeated smoke iterations against the hermetic runtime suite:

```bash
skills/zephyr/scripts/validate_hermetic_runtime_suite.sh \
    --snapshot-ref ghcr.io/phi9t/sygaldry/zephyr:spack@sha256:8c9507aea53995f29a5712c0cbdb99deb3d571fb9631b3d42352b3d6d6fb668c \
    --mode burnin \
    --burnin-iterations 5
```

---

## Packaging

Build a versioned hermetic package for distribution:

```bash
skills/zephyr/scripts/package_mlsys.sh \
    --version <ver> \
    --out-dir <dir> \
    --snapshot-ref ghcr.io/phi9t/sygaldry/zephyr:spack@sha256:8c9507aea53995f29a5712c0cbdb99deb3d571fb9631b3d42352b3d6d6fb668c \
    [--smoke-mode full|skip]
```

---

## Key environment variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `ZEPHYR_CACHE_ROOT` | Host root for all container data | `/mnt/data_infra/zephyr_container_infra` |
| `SYGALDRY_PROJECT_ID` | Per-project isolation namespace | (required for multi-repo) |
| `ZEPHYR_LEASE_MODE` | Enable lease-based container lifecycle | `false` |
| `ZEPHYR_CACHE_PROFILE` | Cache sharing profile | `default` |
| `SYGALDRY_RUN_ID` | Unique run identifier for log isolation | (auto-generated) |
| `MLSYS_DISABLE_GPU` | Skip GPU validation (CPU-only workloads) | `0` |
| `HF_TOKEN` | Token for gated HuggingFace models/datasets | (unset) |

---

## Current snapshot reference

```
ghcr.io/phi9t/sygaldry/zephyr:spack@sha256:8c9507aea53995f29a5712c0cbdb99deb3d571fb9631b3d42352b3d6d6fb668c
```

Spack stack versions baked into this snapshot:
- Python 3.13.8, CUDA 12.9.1
- torch 2.9.0, torchvision 0.24.0, torchaudio 2.9.0
- jax 0.7.0, numpy 2.3.4, scipy 1.16.3
- triton 3.4.0, numba 0.62.0rc2, llvmlite 0.45.0rc2

---

## See also

`foundation.org` — full system design (Pillar 1–7, Skill Distribution SD.1–SD.7)
