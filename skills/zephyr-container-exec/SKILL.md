---
name: zephyr-container-exec
description: Run commands inside the Zephyr container environment with Spack (torch/jax) preferred, manage multiple isolated container runs via SYGALDRY_PROJECT_ID, and monitor long-running jobs using structured logs, status files, and periodic checks. Use for running Python code, installing packages with uv in-container, downloading datasets/models, or launching long-running training jobs with low-token monitoring.
---

# Zephyr Container Exec

## Overview
Run commands inside the Zephyr container with the Spack environment active, using structured logging and minimal-token monitoring. Provide isolation via `SYGALDRY_PROJECT_ID` and shared host mounts for cache/data reuse.

## Quick Start

- **Run a one-off command (Spack preferred):**
  ```bash
  ./container/launch_container.sh bash -lc "cd /workspace/pkg/zephyr && spack env activate . && python -c 'import torch; print(torch.cuda.is_available())'"
  ```

- **Run a long job with structured logging (recommended):**
  ```bash
  /workspace/skills/zephyr-container-exec/scripts/zephyr_job_run.sh \
    --project-id zephyr-a \
    --job-name jax-train \
    -- "cd /workspace/pkg/zephyr && spack env activate . && python train.py"
  ```

- **Check status (low-token):**
  ```bash
  /workspace/skills/zephyr-container-exec/scripts/zephyr_job_status.sh \
    --project-id zephyr-a \
    --job-name jax-train
  ```

## Core Workflow (Task-Based)

### 1) Run Python code in the container (use Spack packages)

Use the Zephyr Spack environment whenever possible so Torch/JAX come from Spack:

```bash
./container/launch_container.sh bash -lc \
  "cd /workspace/pkg/zephyr && spack env activate . && python - <<'PY'
import torch
import jax
print('torch cuda:', torch.cuda.is_available())
print('jax devices:', jax.devices())
PY"
```

### 2) Install packages with uv (isolated per container if needed)

- Prefer Spack for core scientific deps.
- Use uv only for pure-Python packages.
- To isolate uv packages per container run, set a unique `UV_CACHE_DIR`.

Example:
```bash
./container/launch_container.sh bash -lc \
  "export UV_CACHE_DIR=/opt/bazel_cache/uv/zephyr-a && \
   cd /workspace/pkg/zephyr && spack env activate . && \
   uv venv && source .venv/bin/activate && \
   uv add transformers datasets"
```

### 3) Download HuggingFace datasets / model weights

Use a shared host-mounted directory so multiple containers can reuse the data.

```bash
./container/launch_container.sh bash -lc \
  "mkdir -p /opt/bazel_cache/hf && \
   export HF_HOME=/opt/bazel_cache/hf && \
   cd /workspace/pkg/zephyr && spack env activate . && \
   python - <<'PY'
from datasets import load_dataset
load_dataset('wikitext', 'wikitext-103-raw-v1')
PY"
```

## Multi-Container Isolation

- Use **distinct project IDs** to keep caches/home isolated:
  ```bash
  SYGALDRY_PROJECT_ID=zephyr-a ./container/launch_container.sh
  SYGALDRY_PROJECT_ID=zephyr-b ./container/launch_container.sh
  ```
- Each project ID maps to its own host root:
  `/mnt/data_infra/zephyr_container_infra/<project_id>/`
- For *even finer* uv isolation, set `UV_CACHE_DIR` per job or project.

## Long-Running Jobs: Best Practice Monitoring

Use structured logs and a status file. The helper scripts already implement:

- `START`, `PROGRESS`, `DONE/FAILED` markers
- Status file at `/opt/bazel_cache/zephyr_jobs/<job>.status`
- Host log at `/mnt/data_infra/zephyr_container_infra/<project_id>/logs/<job>-<timestamp>.log`

Minimal polling:
```bash
# check status line and last 40 log lines
/workspace/skills/zephyr-container-exec/scripts/zephyr_job_status.sh \
  --project-id zephyr-a --job-name jax-train
```

## Triage Checklist (Low Token)

1. **Is the PID alive?** Use the PID file printed at job start.
2. **Has the status heartbeat advanced?** Check timestamp in status file.
3. **If stalled**, inspect the last 40 log lines only.
4. **If failed**, look for the final `FAILED rc=...` line and extract the error block.

## Resources

### scripts/
- `zephyr_job_run.sh` — run a container job with structured logging
- `zephyr_job_status.sh` — low-token status summary

## Notes
- The launcher does not expose a custom `docker --name` flag; use unique `SYGALDRY_PROJECT_ID` values to isolate runs. If a fixed container name is required, run `docker run` directly.
