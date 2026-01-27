---
name: zephyr
description: Run GPU container jobs with Spack (PyTorch/JAX), build and validate MLSys UV overlay environments, and vendor hermetic Zephyr runtime kits into target repos.
---

# Zephyr

## Overview

This skill provides a GPU-only, vendorable runtime for:

- Container execution with Spack-backed PyTorch/JAX
- Structured background job execution
- MLSys UV overlay environment builds
- Cross-repo vendoring with digest-pinned images

## Runtime Contract

- GPU-only mode; NVIDIA runtime is required.
- Snapshot/base image references must be digest-pinned.
- Vendored runtime must execute from the target repo without source-checkout coupling.

## Install Into Target Repo

```bash
SKILL_DIR="/path/to/skills/zephyr"
TARGET_REPO="/path/to/target-repo"
SNAPSHOT_REF="ghcr.io/phi9t/sygaldry/zephyr:spack@sha256:8c9507aea53995f29a5712c0cbdb99deb3d571fb9631b3d42352b3d6d6fb668c"

"${SKILL_DIR}/scripts/zephyr_vendor_infra.sh" install \
  --target-repo "${TARGET_REPO}" \
  --snapshot-ref "${SNAPSHOT_REF}" \
  --image-mode auto

"${SKILL_DIR}/scripts/zephyr_mlsys_vendor.sh" install \
  --target-repo "${TARGET_REPO}" \
  --snapshot-ref "${SNAPSHOT_REF}" \
  --force
```

## Validate Vendored Infra

```bash
cd "${TARGET_REPO}"
KIT_DIR="$(dirname "$(find . -maxdepth 4 -type f -name repoctl | head -n 1)")"

"${KIT_DIR}/repoctl" config show
"${KIT_DIR}/repoctl" verify image --skip-spack
"${KIT_DIR}/repoctl" verify spack
"${KIT_DIR}/repoctl" verify uv-layering --no-gpu
```

## Run Jobs

```bash
cd "${TARGET_REPO}"
JOBCTL="$(dirname "$(find . -maxdepth 4 -type f -name jobctl | head -n 1)")/jobctl"

"${JOBCTL}" run --project-id zephyr-a --job torch-gpu -- \
  "python -c 'import torch; print(torch.cuda.is_available())'"

"${JOBCTL}" status --project-id zephyr-a --job torch-gpu
"${JOBCTL}" health --project-id zephyr-a --job torch-gpu
"${JOBCTL}" tail --project-id zephyr-a --job torch-gpu --lines 40
```

## MLSys Overlay Runtime

```bash
cd "${TARGET_REPO}"
"${TARGET_REPO}/.codex-zephyr-mlsys/bin/launch-mlsys.sh" hf-transformers --no-validate
"${TARGET_REPO}/.codex-zephyr-mlsys/bin/launch-mlsys.sh" vllm --no-validate
```

## Hermetic Burn-In Suite

Run the full hermetic validation (separate repo + NCCL/JAX/LLVM/CUDA workloads):

```bash
"${SKILL_DIR}/scripts/validate_hermetic_runtime_suite.sh" \
  --snapshot-ref "${SNAPSHOT_REF}" \
  --mode burnin \
  --burnin-iterations 5
```

## Packaging Gates

```bash
"${SKILL_DIR}/scripts/package_infra.sh" \
  --out-dir /tmp/zephyr-dist \
  --version 2026.02.25 \
  --smoke-mode skip \
  --force

"${SKILL_DIR}/scripts/package_mlsys.sh" \
  --out-dir /tmp/zephyr-mlsys-dist \
  --version 2026.02.25 \
  --smoke-mode skip \
  --force
```
