# Zephyr Container Exec — Validation Scenarios

This document defines repo‑scoped validation scenarios for `skills/zephyr-container-exec`.
Each scenario uses the repo skill scripts in `/workspace/skills/zephyr-container-exec/scripts/`.

## Prerequisites

- Docker running and GPU driver compatible with CUDA 12.9.
- Zephyr container image build succeeds (`sygaldry/zephyr:base`).
- Spack environment installed in `pkg/zephyr` (torch + jax CUDA).
- Use distinct project IDs for concurrent runs.

## Conventions

- Use repo‑scoped scripts:
  - `skills/zephyr-container-exec/scripts/zephyr_job_run.sh`
  - `skills/zephyr-container-exec/scripts/zephyr_job_status.sh`
- Each run uses a unique `--project-id`.
- All commands are run from repo root on the host.

---

## Scenario 1: Simple Python command

**Goal:** Verify that a container starts and runs a basic Python command.

```bash
/workspace/skills/zephyr-container-exec/scripts/zephyr_job_run.sh \
  --project-id zephyr-validate-a \
  --job-name py-hello \
  -- "python - <<'PY'
print('hello from python')
PY"

/workspace/skills/zephyr-container-exec/scripts/zephyr_job_status.sh \
  --project-id zephyr-validate-a \
  --job-name py-hello
```

**Expected:** `DONE ... rc=0` and log contains `hello from python`.

---

## Scenario 2: Simple PyTorch CUDA model

**Goal:** Verify CUDA availability and a tiny torch model forward/backward.

```bash
/workspace/skills/zephyr-container-exec/scripts/zephyr_job_run.sh \
  --project-id zephyr-validate-b \
  --job-name torch-gpu \
  -- "cd /workspace/pkg/zephyr && spack env activate . && python - <<'PY'
import torch
assert torch.cuda.is_available(), 'CUDA not available'

device = 'cuda'
model = torch.nn.Sequential(
    torch.nn.Linear(128, 256),
    torch.nn.ReLU(),
    torch.nn.Linear(256, 10),
).to(device)

x = torch.randn(32, 128, device=device)
y = torch.randn(32, 10, device=device)

optim = torch.optim.Adam(model.parameters(), lr=1e-3)
loss_fn = torch.nn.MSELoss()

optim.zero_grad()
loss = loss_fn(model(x), y)
loss.backward()
optim.step()

print('torch cuda ok:', torch.cuda.is_available(), 'loss:', float(loss))
PY"

/workspace/skills/zephyr-container-exec/scripts/zephyr_job_status.sh \
  --project-id zephyr-validate-b \
  --job-name torch-gpu
```

**Expected:** CUDA available, prints loss, `DONE rc=0`.

---

## Scenario 3: Simple JAX CUDA model

**Goal:** Verify JAX GPU device and a simple training step.

```bash
/workspace/skills/zephyr-container-exec/scripts/zephyr_job_run.sh \
  --project-id zephyr-validate-c \
  --job-name jax-gpu \
  -- "cd /workspace/pkg/zephyr && spack env activate . && python - <<'PY'
import jax
import jax.numpy as jnp

assert any(d.platform == 'gpu' for d in jax.devices()), 'JAX GPU not available'

key = jax.random.PRNGKey(0)
W = jax.random.normal(key, (128, 10))

x = jax.random.normal(key, (32, 128))
y = jax.random.normal(key, (32, 10))

@jax.jit
def loss_fn(W, x, y):
    pred = x @ W
    return jnp.mean((pred - y) ** 2)

loss = loss_fn(W, x, y)
print('jax devices:', jax.devices())
print('loss:', float(loss))
PY"

/workspace/skills/zephyr-container-exec/scripts/zephyr_job_status.sh \
  --project-id zephyr-validate-c \
  --job-name jax-gpu
```

**Expected:** GPU device listed, loss printed, `DONE rc=0`.

---

## Scenario 4: HF dataset download (shared across runs)

**Goal:** Download dataset into shared cache and verify reuse from a second container.

**Run 1 (download):**
```bash
/workspace/skills/zephyr-container-exec/scripts/zephyr_job_run.sh \
  --project-id zephyr-validate-d1 \
  --job-name hf-download \
  -- "cd /workspace/pkg/zephyr && spack env activate . && \
     export HF_HOME=/opt/bazel_cache/hf && \
     python - <<'PY'
from datasets import load_dataset
load_dataset('fineweb', 'default', split='train[:0.1%]')
print('downloaded fineweb subset')
PY"
```

**Run 2 (reuse cache):**
```bash
/workspace/skills/zephyr-container-exec/scripts/zephyr_job_run.sh \
  --project-id zephyr-validate-d2 \
  --job-name hf-reuse \
  -- "cd /workspace/pkg/zephyr && spack env activate . && \
     export HF_HOME=/opt/bazel_cache/hf && \
     python - <<'PY'
from datasets import load_dataset
load_dataset('fineweb', 'default', split='train[:0.1%]')
print('reused fineweb subset from cache')
PY"
```

**Expected:** Second run is faster; log indicates cache reuse (no large download).

---

## Scenario 5: HF model inference (Qwen3‑0.6B)

**Goal:** Load a small model and run inference on a tiny dataset slice.

```bash
/workspace/skills/zephyr-container-exec/scripts/zephyr_job_run.sh \
  --project-id zephyr-validate-e \
  --job-name hf-infer \
  -- "cd /workspace/pkg/zephyr && spack env activate . && \
     export HF_HOME=/opt/bazel_cache/hf && \
     python - <<'PY'
from datasets import load_dataset
from transformers import AutoTokenizer, AutoModelForCausalLM
import torch

model_id = 'Qwen/Qwen3-0.6B'

# Load tiny subset
samples = load_dataset('fineweb', 'default', split='train[:0.01%]')
text = samples[0]['text'][:512]

print('loading model...')

tok = AutoTokenizer.from_pretrained(model_id)
model = AutoModelForCausalLM.from_pretrained(model_id, torch_dtype=torch.float16).cuda()

inputs = tok(text, return_tensors='pt').to('cuda')
with torch.no_grad():
    out = model.generate(**inputs, max_new_tokens=32)

print(tok.decode(out[0], skip_special_tokens=True)[:200])
PY"
```

**Expected:** Model downloads to shared cache and inference completes successfully.

---

## Scenario 6: Concurrent runs

**Goal:** Validate multiple concurrent containers with isolated project IDs.

```bash
/workspace/skills/zephyr-container-exec/scripts/zephyr_job_run.sh \
  --project-id zephyr-concurrent-a \
  --job-name torch-a \
  -- "cd /workspace/pkg/zephyr && spack env activate . && python -c 'import torch; print(torch.cuda.is_available())'" &

/workspace/skills/zephyr-container-exec/scripts/zephyr_job_run.sh \
  --project-id zephyr-concurrent-b \
  --job-name jax-b \
  -- "cd /workspace/pkg/zephyr && spack env activate . && python -c 'import jax; print(jax.devices())'" &

/workspace/skills/zephyr-container-exec/scripts/zephyr_job_run.sh \
  --project-id zephyr-concurrent-c \
  --job-name hf-c \
  -- "cd /workspace/pkg/zephyr && spack env activate . && export HF_HOME=/opt/bazel_cache/hf && python -c 'print(\"hf ok\")'" &

wait
```

Check status per project:
```bash
/workspace/skills/zephyr-container-exec/scripts/zephyr_job_status.sh --project-id zephyr-concurrent-a --job-name torch-a
/workspace/skills/zephyr-container-exec/scripts/zephyr_job_status.sh --project-id zephyr-concurrent-b --job-name jax-b
/workspace/skills/zephyr-container-exec/scripts/zephyr_job_status.sh --project-id zephyr-concurrent-c --job-name hf-c
```

**Expected:** Each run completes independently with its own logs and status file.
