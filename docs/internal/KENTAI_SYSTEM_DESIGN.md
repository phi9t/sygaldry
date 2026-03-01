# Kentai System Architecture

> K3s + Temporal + Zephyr/MLSys container infrastructure for GPU workload orchestration.

**Version:** 2026-02-26
**Status:** Launch Review

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Architecture Overview](#2-system-architecture-overview)
3. [Container Infrastructure](#3-container-infrastructure)
4. [Runtime Execution Modes](#4-runtime-execution-modes)
5. [K3s Subsystem](#5-k3s-subsystem)
6. [Temporal Orchestration](#6-temporal-orchestration)
7. [Operational Runbook](#7-operational-runbook)
8. [Security Model](#8-security-model)
9. [Limitations & Constraints](#9-limitations--constraints)
10. [Test Coverage](#10-test-coverage)
11. [Future Work](#11-future-work)

---

## 1. Executive Summary

Kentai is a unified GPU workload orchestration system built on three pillars:

- **Docker containers** — environment isolation with NVIDIA CUDA 12.9.1 base, hermetic Python/C++/Rust builds via Spack
- **K3s** — single-node Kubernetes scheduling for persistent dev pods and batch jobs with GPU resource management
- **Temporal** — DAG-based pipeline orchestration with 9 step types, template composition, and structured logging

The system provides two equivalent execution paths — Docker (direct) and K3s (scheduled) — with identical container images, entrypoints, and volume layouts. Temporal sits above both as the pipeline layer, dispatching steps to either backend.

**Key design constraint:** This is a **GPU-only** infrastructure. Every container assumes NVIDIA runtime access. The 42 GB Spack store (PyTorch 2.9, JAX 0.7, Triton 3.4, CUDA 12.9.1) is a precious shared artifact that is never copied — only mounted.

**Primary CLI tools:**

| Tool | Purpose |
|------|---------|
| `sygaldry` | Unified CLI (shell, run, job, k3s, validate) |
| `kentai` | K3s interactive dev pods (create, attach, exec, delete) |
| `kjob` | K3s batch job management (run, status, tail, stop, list) |
| `go run ./cmd/orchestrate` | Temporal pipeline execution and validation |

---

## 2. System Architecture Overview

### 2.1 Design Principles

1. **Hermetic builds** — Spack manages system-level scientific libraries (PyTorch, JAX, CUDA, cuDNN, MPI). UV layers Python packages on top with constraints that prevent overriding Spack-owned packages.

2. **Precious artifacts** — The Spack store is expensive to build (hours of compilation). It is baked into snapshot images and mounted read-only at runtime. It is never moved, copied, or rebuilt unless intentional.

3. **Docker/K3s parity** — Same images, same entrypoints, same volume layout. The only difference is scheduling semantics (Docker `--runtime=nvidia` vs K8s `runtimeClassName: nvidia`).

4. **Project isolation** — Each project gets its own home directory, workspace, and config on the host. Shared caches (HuggingFace, UV, Torch kernels, Triton, JAX XLA) are mounted from a common location.

5. **Single-node simplicity** — K3s runs on one machine. No PV/PVC, no ingress controllers, no service mesh. Direct `hostPath` mounts everywhere. The complexity budget is spent on GPU management and pipeline orchestration, not distributed systems.

### 2.2 Three-Tier Container Build Pipeline

```
Tier 1: Base Image
  nvidia/cuda:12.9.1-devel-ubuntu24.04
  + build-essential, cmake, git, curl, tmux, jq
  + Go 1.24.1, Rust 1.79.0, uv (Python package manager)
  + Spack source at /opt/spack_src
  + Container user kvothe (host UID/GID mapping)
  → sygaldry/zephyr:base (~8 GB)

Tier 2: Spack Snapshot
  + Spack install_tree baked into image
    PyTorch 2.9.0, JAX 0.7.0, Triton 3.4.0
    NumPy 2.3.4, SciPy 1.16.3, Python 3.13.8
    CUDA 12.9.1, cuDNN, NCCL, MPI
  + Spack view at /opt/spack_store/view
  + Entrypoints + lib baked at /opt/container_entrypoints, /opt/lib
  → sygaldry/zephyr:spack-<timestamp> (~37 GB)

Tier 3: MLSys Venv (parameterized)
  + UV venv with LLM serving packages
    Variants: hf, vllm, sglang, mlsys (all-in-one)
  + Constraint-pinned to Spack versions
  + Auto-activation via shell integration
  → sygaldry/zephyr:{hf|vllm|sglang|mlsys} (~60 GB)
```

### 2.3 Component Map

```
┌──────────────────────────────────────────────────────────────────┐
│                        User CLI Layer                            │
│                                                                  │
│  sygaldry ─── shell/run ──→ launch_container.sh (Docker)         │
│           ├── k3s enter ──→ kentai (K3s dev pod)                 │
│           ├── k3s job ────→ kjob (K3s batch job)                 │
│           ├── job ────────→ zephyr_job (Docker job runner)        │
│           └── validate ───→ validate_all.sh                      │
│                                                                  │
│  go run ./cmd/orchestrate ──→ Temporal pipeline submission       │
│  go run ./cmd/worker ───────→ Temporal activity worker           │
├──────────────────────────────────────────────────────────────────┤
│                     Orchestration Layer                           │
│                                                                  │
│  Temporal Server ← Pipeline Workflow ← YAML Plan                 │
│       │                                                          │
│       ├── command, download, docker_build, docker_push           │
│       ├── package_build, container_job (Docker)                  │
│       ├── hf_download_dataset, hf_download_model                 │
│       └── k8s_job (K3s)                                          │
├──────────────────────────────────────────────────────────────────┤
│                     Scheduling Layer                             │
│                                                                  │
│  Docker ──→ docker run --runtime=nvidia --gpus=all               │
│  K3s ────→ kubectl apply (Pod/Job with runtimeClassName: nvidia)  │
├──────────────────────────────────────────────────────────────────┤
│                     Container Layer                              │
│                                                                  │
│  NVIDIA CUDA 12.9.1 │ Ubuntu 24.04 │ Spack │ UV │ Entrypoints   │
│                                                                  │
│  /opt/spack_store/view (42 GB, read-only)                        │
│  /opt/container_entrypoints/{default,run-job,verify-gpu,...}.sh   │
│  /opt/lib/spack_init.sh (Spack + CUDA + venv initialization)     │
├──────────────────────────────────────────────────────────────────┤
│                     Host Storage Layer                            │
│                                                                  │
│  /mnt/data_infra/zephyr_container_infra/                         │
│    projects/<id>/{home,config,workspace,outputs,local_share}     │
│    shared/{hf_cache,uv_cache,bazel_cache,torch_cache,...}        │
│    sygaldry/spack_store (42 GB, precious)                        │
└──────────────────────────────────────────────────────────────────┘
```

### 2.4 Technology Stack

| Component | Technology | Version |
|-----------|-----------|---------|
| Base OS | Ubuntu | 24.04 |
| GPU Runtime | NVIDIA CUDA | 12.9.1 |
| Container Runtime | Docker + containerd (K3s) | - |
| Kubernetes | K3s | latest stable |
| Python | CPython (Spack-built) | 3.13.8 |
| ML Frameworks | PyTorch, JAX | 2.9.0, 0.7.0 |
| Compiler | Triton | 3.4.0 |
| Scientific | NumPy, SciPy, numba | 2.3.4, 1.16.3, 0.62.0rc2 |
| Python Packaging | uv | latest |
| HPC Packaging | Spack | 0.23.x |
| Orchestration | Temporal | dev server / Docker |
| Orchestration Code | Go | 1.24.1 |
| Build Tool | GNU Make | - |
| Shell | Bash | 5.x |

---

## 3. Container Infrastructure

### 3.1 Base Image (`dev_container.dockerfile`)

The base image starts from `nvidia/cuda:12.9.1-devel-ubuntu24.04` and layers:

1. **System packages** — build-essential, cmake, git, curl, wget, tmux, jq, htop, socat, envsubst, and other development essentials
2. **Go** — version 1.24.1, installed to `/usr/local/go`
3. **Rust** — version 1.79.0 via rustup
4. **uv** — Python package manager (replaces pip for all user-facing installs)
5. **Spack source** — cloned to `/opt/spack_src` with setup scripts
6. **CUDA/cuDNN compatibility** — symlinks and `ld.so.conf.d` entries for runtime library discovery
7. **Container user** — `kvothe` created with `ARG HOST_UID/HOST_GID` for seamless host file permissions
8. **Entrypoints** — copied to `/opt/container_entrypoints/`

The base image is ~8 GB and contains no compiled Spack packages. It is the foundation for all other tiers.

### 3.2 Spack Snapshot Layer (`spack_snapshot.dockerfile`)

Builds on top of the base image by baking the Spack install tree into the image:

1. Copies `spack_store/{install_tree,view,db}` from build context
2. Copies `pkg/zephyr/` environment metadata (spack.yaml, spack.lock)
3. Bakes entrypoints and lib at `/opt/container_entrypoints/`, `/opt/lib/`
4. Runs `spack reindex` to rebuild the Spack database inside the image
5. Regenerates the Spack view at `/opt/spack_store/view`
6. Configures MLSys environment variables

The snapshot image is ~37 GB. The Spack view provides a unified `/opt/spack_store/view/bin/python3` with all scientific packages importable without activation.

**Build command:**
```bash
make -C container spack-snapshot
```

### 3.3 MLSys Venv Layer (`mlsys_venv.dockerfile`)

Parameterized Dockerfile that creates UV virtual environments on top of the snapshot:

- **Build arg:** `MLSYS_ENV` selects the variant (`hf`, `vllm`, `sglang`, `mlsys`)
- Creates a UV venv at `/opt/mlsys/<env>/` using Spack Python with `--system-site-packages`
- Installs LLM serving packages (transformers, vLLM, sglang, etc.) constrained to Spack versions
- Adds `.pth` file linking Spack view site-packages into the venv
- Configures shell integration for auto-activation on container entry
- Supports venv switching via `mlsys-activate <name>` helper

The MLSys image is ~60 GB (Spack snapshot + venv packages).

### 3.4 UV-Spack Layering Strategy

The central challenge is installing Python packages (via UV/pip) that depend on libraries already provided by Spack (torch, numpy, jax, etc.) without overriding or conflicting.

**Three mechanisms work together:**

1. **Constraint file** — Generated at install time by scanning Spack's installed distributions and pinning exact versions (e.g., `torch==2.9.0`, `numpy==2.3.4`). Prevents UV from installing different versions.

2. **NVIDIA overrides** (`container/nvidia_overrides.txt`) — Blocks all `nvidia-cuda-*`, `nvidia-cublas-*`, `nvidia-cudnn-*` pip packages using `sys_platform == 'never'` markers. These are already provided by CUDA toolkit and Spack.

3. **LLM serving overrides** (`container/llm_serving_overrides.txt`) — Relaxes narrow version pins from packages like vLLM and sglang (e.g., `triton>=3.4.0` instead of `triton==3.5.0`). Blocks `torch` from pip entirely since it comes from Spack.

**Spack-owned packages** (15 packages defined in `container/spack_owned_packages.conf`):
```
torch, torchvision, torchaudio, jax, jaxlib, triton,
numpy, scipy, scikit-learn, numba, llvmlite,
matplotlib, pandas, soundfile, jupyterlab
```

UV is configured with `UV_NO_BUILD_ISOLATION_PACKAGE` set to this list, preventing UV from building these in isolation (which would pull its own torch, numpy, etc.).

### 3.5 Image Label-Driven Logic

Docker labels on images carry metadata used by runtime scripts:

- `sygaldry.mlsys_env` — Which MLSys variant is baked in
- `sygaldry.spack_snapshot` — Timestamp of the Spack snapshot
- `sygaldry.build_date` — Image build timestamp

Entrypoint scripts read these labels to auto-activate the correct venv and configure environment paths.

---

## 4. Runtime Execution Modes

### 4.1 Docker Mode (`launch_container.sh`)

The original and default execution mode. `launch_container.sh` is a ~400-line bash script that:

1. Resolves the container image (default: `sygaldry/zephyr:base`, overridable via `SYGALDRY_IMAGE`)
2. Creates host directories under `/mnt/data_infra/zephyr_container_infra/<project_id>/`
3. Constructs a `docker run` command with:
   - `--runtime=nvidia --gpus=all`
   - `--net=host --ipc=host`
   - `--user=$(id -u):$(id -g)`
   - Volume mounts (home, config, workspace, shared caches, Spack store)
4. Selects entrypoint (default: `default.sh`, overridable via `--entrypoint`)
5. Passes remaining arguments to the container

**Usage:**
```bash
./container/launch_container.sh                                    # Interactive
./container/launch_container.sh --entrypoint run-job.sh -- "cmd"   # Run command
./container/launch_container.sh --repo /path/to/repo               # Multi-repo
```

### 4.2 K3s Mode (`kentai` + `kjob`)

K3s mode provides Kubernetes-scheduled execution with the same container images:

**`kentai` — Interactive dev pods:**
- Creates a Kubernetes Pod with `runtimeClassName: nvidia`
- Pod runs `sleep infinity` with a tmux session for persistent interactive access
- Reconnecting (`kentai --project-id X`) re-attaches to the existing tmux session
- Subcommands: `enter` (default), `exec`, `delete`, `status`, `logs`

**`kjob` — Batch jobs:**
- Creates a Kubernetes Job with `backoffLimit: 0` and `ttlSecondsAfterFinished: 86400`
- Job pod runs `/opt/container_entrypoints/run-job.sh` with the user command
- Subcommands: `run`, `status`, `tail`, `stop`, `list`
- Idempotent: re-submitting deletes the old job first

Both tools share `k3s/lib/k3s-common.sh` for cluster checks, host directory setup, and pod helpers.

### 4.3 Docker ↔ K3s Parity Matrix

| Aspect | Docker Mode | K3s Mode |
|--------|------------|----------|
| GPU access | `--runtime=nvidia --gpus=all` | `runtimeClassName: nvidia` + `nvidia.com/gpu: N` |
| Network | `--net=host` | `hostNetwork: true` |
| IPC | `--ipc=host` | `hostIPC: true` |
| User mapping | `--user=UID:GID` | `securityContext.runAsUser/runAsGroup/fsGroup` |
| Volumes | `-v host:container` | `hostPath` volumes |
| Image source | Local Docker daemon | containerd (imported via `import-image.sh`) |
| Persistence | Container removed on exit | Pod persists (tmux); jobs have 24h TTL |
| Entrypoints | Same (`/opt/container_entrypoints/`) | Same |
| Spack env | Same (`/opt/spack_store/view`) | Same |
| Multi-repo | `--repo <path>` | `--repo <path>` (multirepo template) |
| Orchestration | `container_job` step type | `k8s_job` step type |
| CLI | `sygaldry shell/run` | `sygaldry k3s enter/job` or `kentai`/`kjob` |
| GPU selection | All GPUs | N GPUs via resource limits |
| Restart policy | None | `Never` (pods), `Never` (jobs) |

### 4.4 Multi-Repo Mode

Both Docker and K3s support mounting an external repository into the container:

```bash
# Docker
sygaldry --repo /path/to/ml-project

# K3s
kentai --repo /path/to/ml-project
```

**What changes in multi-repo mode:**
- Sygaldry repo mounts read-only at `/opt/sygaldry`
- External repo mounts at `/workspace/<repo_name>`
- Working directory is set to `/workspace/<repo_name>`
- Spack store, UV cache, HF cache remain shared from the sygaldry project
- Per-project home/workspace/config are isolated under the project ID

---

## 5. K3s Subsystem

### 5.1 Bootstrap Sequence

| Step | Command | What Happens | Expected Outcome |
|------|---------|-------------|-----------------|
| 1 | `sudo k3s/bootstrap/install-k3s.sh` | Downloads K3s binary via get.k3s.io, installs as systemd service with `--disable=traefik --disable=servicelb`, copies kubeconfig to `~/.kube/config` with mode 600 | K3s running on localhost:6443, `kubectl get nodes` shows Ready |
| 2 | `sudo k3s/bootstrap/setup-nvidia.sh` | Writes containerd config template with nvidia runtime handler, restarts K3s, creates `sygaldry` namespace, applies RuntimeClass + ConfigMap, deploys NVIDIA device plugin v0.17.0 DaemonSet | `kubectl get runtimeclass nvidia` exists, `nvidia.com/gpu` allocatable on node |
| 3 | `sudo k3s/bootstrap/import-image.sh <image>` | Checks if image already in containerd, exports from Docker via `docker save`, imports via nerdctl (preferred) or `k3s ctr images import`, saves tarball to `/var/lib/rancher/k3s/agent/images/` for restart persistence | `sudo k3s crictl images` shows image, persists across K3s restarts |

**Teardown:** `sudo k3s/bootstrap/teardown.sh` runs the K3s uninstall script.

### 5.2 NVIDIA GPU Integration

K3s GPU support requires three components:

1. **containerd config template** — Written to `/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl` with the `nvidia` runtime handler pointing to `nvidia-container-runtime`

2. **RuntimeClass** — Kubernetes `RuntimeClass` named `nvidia` with handler `nvidia`. All pods/jobs reference this via `spec.runtimeClassName: nvidia`

3. **Device plugin** — NVIDIA k8s-device-plugin v0.17.0 DaemonSet in `kube-system` namespace. Advertises `nvidia.com/gpu` as an allocatable resource. Pods request GPUs via `resources.limits.nvidia.com/gpu: N`

`setup-nvidia.sh` polls for up to 150 seconds (30 iterations × 5s) waiting for GPU resources to appear in node status.

### 5.3 Manifests & Templates

**Static manifests** (`k3s/manifests/`):

| File | Resource | Purpose |
|------|----------|---------|
| `namespace.yaml` | Namespace `sygaldry` | Isolates all Sygaldry workloads |
| `nvidia-runtime-class.yaml` | RuntimeClass `nvidia` | Maps to containerd nvidia handler |
| `configmap-env.yaml` | ConfigMap `sygaldry-env` | Environment variables injected into all pods |

**Templates** (`k3s/templates/`) — processed via `envsubst`:

| Template | Variables | Purpose |
|----------|-----------|---------|
| `dev-pod.yaml` | PROJECT_ID, HOST_UID, HOST_GID, CONTAINER_IMAGE, GPU_COUNT | Interactive dev pod |
| `dev-pod-multirepo.yaml` | + REPO_HOST_PATH, REPO_NAME | Multi-repo dev pod |
| `job.yaml` | + JOB_NAME, JOB_COMMAND | Batch job |

### 5.4 Volume Architecture

Every pod mounts 17-18 `hostPath` volumes:

```
Per-Project (5 mounts):
  /home/kvothe          ← projects/<id>/home
  /home/kvothe/.config  ← projects/<id>/config
  /home/kvothe/.local/share ← projects/<id>/local_share
  /workspace/outputs    ← projects/<id>/outputs
  /workspace            ← projects/<id>/workspace

Shared Caches (7 mounts):
  /opt/hf_cache         ← shared/hf_cache         (HuggingFace models/datasets)
  /opt/uv_cache         ← shared/uv_cache         (UV package downloads)
  /opt/bazel_cache      ← shared/bazel_cache       (Bazel builds)
  /opt/torch_cache      ← shared/torch_cache       (PyTorch kernel cache)
  /opt/triton_cache     ← shared/triton_cache      (Triton kernel cache)
  /opt/nv_compute_cache ← shared/nv_compute_cache  (CUDA compute cache)
  /opt/jax_cache        ← shared/jax_cache         (JAX XLA compilation cache)

Precious Artifact (1 mount, read-only):
  /opt/spack_store      ← sygaldry/spack_store     (42 GB, NEVER move/copy)

Code Mounts (4-5, read-only from sygaldry repo):
  /opt/container_entrypoints  ← container/entrypoints
  /opt/lib                    ← container/lib
  /opt/spack_env/default      ← pkg/zephyr
  /opt/spack_env/entrypoints  ← container/entrypoints (compat alias)
  /opt/spack_env/lib          ← container/lib (compat alias)

Host root: /mnt/data_infra/zephyr_container_infra/
```

All mounts use `DirectoryOrCreate` type except the Spack store (`Directory` — must pre-exist) and code mounts (`Directory`).

### 5.5 Pod Lifecycle (`kentai`)

```
kentai --project-id ml-research
  │
  ├─ check_k3s()           # kubectl cluster-info reachable?
  ├─ check_namespace()     # sygaldry namespace exists?
  ├─ check_nvidia_runtime() # nvidia RuntimeClass exists?
  │
  ├─ pod_status() → Running?
  │   ├─ Yes → attach_tmux() (re-attach to existing session)
  │   ├─ "" (not found) → create_pod() → wait_pod_ready(120s) → attach_tmux()
  │   └─ Other → delete pod → create_pod() → wait_pod_ready(120s) → attach_tmux()
  │
  └─ Pod runs:
      1. Source /opt/lib/spack_init.sh → sygaldry_full_init
      2. tmux new-session -d -s main
      3. exec sleep infinity (keeps pod alive)
```

Users interact via tmux: `Ctrl-b d` to detach, `kentai` to re-attach. Pod state (running processes, files, venvs) persists across detach/attach cycles. Host directories persist across pod deletion/recreation.

### 5.6 Batch Jobs (`kjob`)

```
kjob run --project-id ml-research --job train-v1 -- "python train.py"
  │
  ├─ Validates: project-id, job name, command
  ├─ check_k3s, check_namespace, check_nvidia_runtime
  ├─ ensure_host_dirs()
  ├─ Delete existing job if present (idempotent)
  └─ envsubst < job.yaml | kubectl apply
      │
      └─ Job spec:
          backoffLimit: 0        (no retries at K8s level)
          ttlSecondsAfterFinished: 86400  (24h auto-cleanup)
          container:
            command: /opt/container_entrypoints/run-job.sh
            args: ["bash", "-c", "<user_command>"]
```

Job naming convention: `sygaldry-job-<project_id>-<job_name>`

---

## 6. Temporal Orchestration

### 6.1 Architecture

```
┌─────────────┐     ┌──────────────┐     ┌──────────────────┐
│ YAML Plan   │────→│ Orchestrate  │────→│ Temporal Server   │
│ (pipeline)  │     │ CLI          │     │ (dev or Docker)   │
└─────────────┘     │ - validate   │     │                   │
                    │ - submit     │     │ Workflow History   │
                    └──────────────┘     └────────┬──────────┘
                                                  │
                                         ┌────────▼──────────┐
                                         │ Worker Process     │
                                         │                    │
                                         │ Pipeline Workflow  │
                                         │   ├─ DAG resolver  │
                                         │   ├─ Template sub  │
                                         │   └─ Step dispatch │
                                         │                    │
                                         │ Activities:        │
                                         │   command, download│
                                         │   docker_build/push│
                                         │   package_build    │
                                         │   container_job    │
                                         │   hf_download_*    │
                                         │   k8s_job          │
                                         └────────────────────┘
```

**Components:**
- **Temporal Server** — can run as `temporal server start-dev` (UI at :8233) or via Docker Compose (UI at :8080)
- **Worker** — Go process that registers the Pipeline workflow and all 9 activities
- **Orchestrate CLI** — submits YAML plans, validates, queries status

### 6.2 Step Types (9 Activities)

| Type | Activity | Description |
|------|----------|-------------|
| `command` | RunCommand | Execute arbitrary shell command |
| `download` | Download | HTTP download with optional SHA256 verification |
| `docker_build` | DockerBuild | Build Docker image with build-args and labels |
| `docker_push` | DockerPush | Push image to registry |
| `package_build` | PackageBuild | Run package build command (e.g., Spack install) |
| `container_job` | ContainerJob | Run command in Sygaldry Docker container with GPU |
| `hf_download_dataset` | HFDownloadDataset | Download HuggingFace dataset via Python |
| `hf_download_model` | HFDownloadModel | Download HuggingFace model via snapshot_download |
| `k8s_job` | K8sJob | Submit batch job to K3s via `kjob` CLI |

Each activity receives structured input, writes JSONL logs per step, captures stdout/stderr with configurable truncation (default 10 KB), and emits events to `events.jsonl`.

### 6.3 DAG Execution Engine

The pipeline workflow implements a dependency-aware DAG executor:

1. **Initialization** — all steps start as `pending`
2. **Ready check** — a step is ready when all `depends_on` steps have completed
3. **Dispatch** — ready steps are launched as Temporal activities with per-step timeout
4. **Selector** — async Temporal selector awaits completion of any running step
5. **Completion** — step outcome (success/failure/skipped) recorded, triggers re-evaluation of pending steps
6. **When clauses** — conditional execution based on upstream step outcomes:
   ```yaml
   when:
     - step: build
       status: success    # Only run if build succeeded
   ```
7. **Allow failure** — `allow_failure: true` lets a step fail without halting the pipeline
8. **Termination** — pipeline completes when all steps are resolved (completed, failed, or skipped)

**Cycle detection** — the orchestrate CLI validates dependency graphs using DFS with white/gray/black node coloring before submission.

### 6.4 Template & Parameter System

**Parameters** — defined at plan level, overridable via `-set key=value`:
```yaml
params:
  model_id: Qwen/Qwen3-0.6B-Base
  epochs: 10

steps:
  - id: train
    type: k8s_job
    k8s_job:
      command: "python train.py --model ${{ params.model_id }} --epochs ${{ params.epochs }}"
```

**Output consumption** — steps can set outputs via stdout markers:
```bash
echo "::set-output name=model_path::/opt/hf_cache/models/qwen3"
```
Downstream steps reference: `${{ steps.download.outputs.model_path }}`

**Template imports** — reusable step definitions loaded from external files:
```yaml
imports:
  - path: templates/gpu-steps.yaml

steps:
  - id: train
    template: gpu-train    # References imported template
    k8s_job:
      command: "python train.py"  # Merges with template defaults
```

Template resolution uses recursive reflection-based string replacement across all string fields in step specs.

### 6.5 Logging & Observability

Every pipeline execution produces:

```
logs/
  <workflow_id>_<run_id>_plan.json     # Full plan manifest
  <workflow_id>_<run_id>/
    events.jsonl                        # Pipeline-level events
    <step_id>/
      stdout.log                        # Step stdout
      stderr.log                        # Step stderr
      structured.jsonl                  # Per-line JSON logs
```

**Structured log format:**
```json
{
  "timestamp": "2026-02-26T12:00:00Z",
  "workflow_id": "pipeline-abc123",
  "run_id": "run-def456",
  "step_id": "train",
  "stream": "stdout",
  "line": "Epoch 1/10: loss=2.34"
}
```

**CLI inspection:**
```bash
./scripts/logs_cli.py list-runs
./scripts/logs_cli.py show-steps --workflow-id <id> --run-id <run>
./scripts/logs_cli.py follow --workflow-id <id> --run-id <run>
```

### 6.6 K8sJob Integration

The `k8s_job` step type bridges Temporal workflows with K3s batch jobs:

```yaml
- id: train
  type: k8s_job
  k8s_job:
    project_id: ml-research
    command: "python train.py --epochs 10"
    gpu: true
    gpu_count: 2
    image: sygaldry/zephyr:hf
```

**Execution flow:**
1. Temporal activity invokes `kjob run` with the specified parameters
2. `kjob` creates a K8s Job in the `sygaldry` namespace
3. Activity polls for job completion (kubectl get job status)
4. Stdout/stderr captured and returned as activity result
5. Non-zero exit code returned as result (not error) — workflow decides behavior

---

## 7. Operational Runbook

### 7.1 Bootstrap (First-Time Setup)

```bash
# Prerequisites: NVIDIA driver + nvidia-container-toolkit installed

# Step 1: Install K3s
sudo k3s/bootstrap/install-k3s.sh
# Verify: kubectl get nodes → Ready

# Step 2: Configure NVIDIA runtime + device plugin
sudo k3s/bootstrap/setup-nvidia.sh
# Verify: kubectl get runtimeclass nvidia
# Verify: kubectl describe node | grep nvidia.com/gpu

# Step 3: Import container image
sudo k3s/bootstrap/import-image.sh sygaldry/zephyr:spack-20260212-082355
# Verify: sudo k3s crictl images | grep sygaldry

# Step 4: Install CLI (optional)
ln -s /mnt/data_infra/workspace/sygaldry/bin/sygaldry /usr/local/bin/sygaldry
ln -s /mnt/data_infra/workspace/sygaldry/bin/kentai /usr/local/bin/kentai
ln -s /mnt/data_infra/workspace/sygaldry/k3s/bin/kjob /usr/local/bin/kjob
```

### 7.2 Interactive Development Session

```bash
# Create or attach to dev pod
kentai --project-id ml-research --gpu 2

# What happens:
#   1. Checks K3s cluster, namespace, RuntimeClass
#   2. Creates host dirs: projects/ml-research/{home,config,workspace,...}
#   3. Applies dev-pod.yaml template via envsubst | kubectl apply
#   4. Waits for pod Ready (up to 120s)
#   5. Attaches to tmux session "main" inside pod
#
# Expected: Interactive bash shell with Spack activated, GPU visible

# Detach: Ctrl-b d
# Re-attach later:
kentai --project-id ml-research
# Same tmux session — all state preserved

# Run one-off command in existing pod:
kentai exec --project-id ml-research -- nvidia-smi

# Check pod status:
kentai status --project-id ml-research

# Delete pod (host dirs persist):
kentai delete --project-id ml-research
```

### 7.3 Submit a Batch Job

```bash
# Submit job
kjob run --project-id ml-research --job train-v1 --gpu 2 -- "python train.py --epochs 10"

# What happens:
#   1. Validates project-id, job name, command
#   2. Creates host dirs if needed
#   3. Deletes existing job with same name (idempotent)
#   4. Applies job.yaml template: backoffLimit=0, ttlSecondsAfterFinished=86400
#   5. Pod runs /opt/container_entrypoints/run-job.sh with the command
#
# Expected: "Job sygaldry-job-ml-research-train-v1 submitted."

# Monitor
kjob tail --project-id ml-research --job train-v1

# Check status
kjob status --project-id ml-research --job train-v1

# List all jobs for project
kjob list --project-id ml-research

# Stop if needed
kjob stop --project-id ml-research --job train-v1
```

### 7.4 Run a Temporal Pipeline

```bash
# Step 1: Start Temporal server (one terminal)
cd temporal && ./scripts/start-temporal.sh
# UI at http://localhost:8233

# Step 2: Start worker (another terminal)
cd temporal && TEMPORAL_ADDRESS=localhost:7233 go run ./cmd/worker

# Step 3: Submit pipeline
cat > /tmp/pipeline.yaml << 'EOF'
params:
  model_id: Qwen/Qwen3-0.6B-Base
steps:
  - id: download-model
    type: hf_download_model
    hf_download_model:
      model_id: ${{ params.model_id }}

  - id: gpu-check
    type: k8s_job
    depends_on: [download-model]
    k8s_job:
      project_id: ml-research
      command: "nvidia-smi && python -c 'import torch; print(torch.cuda.is_available())'"
      gpu: true
      gpu_count: 1

  - id: train
    type: k8s_job
    depends_on: [gpu-check]
    k8s_job:
      project_id: ml-research
      command: "python train.py --model ${{ params.model_id }} --epochs 5"
      gpu: true
      gpu_count: 2
      image: sygaldry/zephyr:hf
EOF

go run ./cmd/orchestrate run -plan /tmp/pipeline.yaml -set model_id=Qwen/Qwen3-0.6B-Base

# What happens:
#   1. Validates plan (deps, types, required fields, cycle detection)
#   2. Submits Pipeline workflow to Temporal
#   3. Worker picks up workflow, DAG executor runs steps in dependency order
#   4. Each k8s_job step calls kjob run → K3s batch job
#   5. Structured JSONL logs written to logs/ directory
#
# Expected: All 3 steps succeed, workflow completes

# Validate without running:
go run ./cmd/orchestrate validate -plan /tmp/pipeline.yaml
```

### 7.5 Build & Import Custom Image

```bash
# Build base image
make -C container container

# Build Spack snapshot (requires existing spack_store with compiled packages)
make -C container spack-snapshot

# Build MLSys venv layer
make -C container mlsys-venv MLSYS_ENV=hf

# Import into K3s
sudo k3s/bootstrap/import-image.sh sygaldry/zephyr:hf
```

### 7.6 Teardown

```bash
# Delete all pods and jobs in sygaldry namespace
kubectl delete pods,jobs -n sygaldry --all

# Uninstall K3s
sudo k3s/bootstrap/teardown.sh

# Host directories at /mnt/data_infra/zephyr_container_infra/ are NOT deleted
# (they contain user data, model caches, etc.)
```

---

## 8. Security Model

**Host trust model:** Single-user, single-node infrastructure. The host is trusted. No multi-tenancy.

| Aspect | Implementation |
|--------|---------------|
| Container user | `kvothe` with host UID/GID mapping (no root in container) |
| Network | `hostNetwork: true` (no network isolation — same as Docker `--net=host`) |
| IPC | `hostIPC: true` (required for NCCL multi-GPU communication) |
| Image pull | `imagePullPolicy: Never` (no registry, local images only) |
| Volumes | `hostPath` only (no network storage, no secrets volumes) |
| Spack store | Read-only mount (`readOnly: true`) |
| Code mounts | Read-only from sygaldry repo |
| RBAC | Not configured (single-user, kubeconfig has full cluster access) |
| Secrets | HF_TOKEN via environment variable (not K8s Secret) |
| Build role | `SYGALDRY_BUILD_ROLE=builder` required for Spack builds (prevents accidental rebuilds in consumer mode) |

**No external network exposure.** K3s is installed with `--disable=traefik --disable=servicelb`. No ingress, no load balancer, no external service endpoints.

---

## 9. Limitations & Constraints

| Limitation | Impact | Mitigation |
|-----------|--------|------------|
| Single-node only | Cannot distribute across machines | Sufficient for single-workstation GPU research |
| GPU-only | No CPU-only mode | By design — all workloads assume CUDA |
| No multi-tenancy | Single user per installation | Host UID mapping provides file permission safety |
| No container registry | Images must be imported manually | `import-image.sh` with restart persistence |
| No PV/PVC | No dynamic storage provisioning | `hostPath` is simpler and faster for single-node |
| 42 GB Spack store | Large image sizes, long import times | Baked into snapshot image, mounted read-only |
| No Rust in snapshot image | Source builds requiring Rust fail (e.g., outlines-core) | Use base image for Rust-dependent builds |
| hostNetwork/hostIPC | No network isolation | Required for NCCL; acceptable for single-user |
| Spack rebuild cost | Hours of compilation | Snapshot images + lockfiles prevent unnecessary rebuilds |
| Template resolution | String-only (no conditionals, no loops) | When-clauses provide basic branching |

---

## 10. Test Coverage

### Go Tests (Temporal)

```bash
cd temporal && go test ./...
```

**89 test cases** across three packages:

| Package | Tests | Coverage Areas |
|---------|-------|---------------|
| `cmd/orchestrate/` | Plan validation | Step types, dependencies, when-clauses, required fields, cycle detection, duplicate IDs |
| `internal/activities/` | Activity execution | Command execution, log writers, input validation, stdout/stderr truncation, exit code handling |
| `internal/workflows/` | Workflow engine | Dependency resolution, skip logic, step ordering, template expansion, output parsing, retry |

### Shell Validation

```bash
shellcheck -s bash -S warning k3s/bin/kentai k3s/bin/kjob k3s/lib/k3s-common.sh
shellcheck -s bash -S warning k3s/bootstrap/*.sh
shellcheck -s bash -S warning container/entrypoints/*.sh
```

### Full Validation Suite

```bash
./validate_all.sh              # go build/vet/test, ruff, black, shellcheck, pytest
./validate_all.sh --quick      # Skip shellcheck
./validate_all.sh --verify-only # Spack/GPU verification only
```

### GPU Verification

```bash
# Inside container (Docker or K3s):
gpu-test                       # Quick PyTorch CUDA check
jax-test                       # Quick JAX GPU check

# Via entrypoint:
kentai exec --project-id test -- /opt/container_entrypoints/verify-gpu.sh
```

---

## 11. Future Work

1. **Multi-node K3s** — Scale beyond single workstation. Requires network storage (NFS/Ceph for shared caches), proper RBAC, and node affinity for GPU scheduling.

2. **Container registry** — Replace manual `import-image.sh` with a local registry (Harbor or K3s embedded registry). Enables image versioning and rollback.

3. **Temporal UI integration** — Web-based pipeline submission and monitoring beyond the CLI. The `temporal/visualizer/` directory contains a Node.js prototype.

4. **Quota management** — GPU resource quotas per project to prevent starvation when multiple projects share the same node.

5. **Checkpoint/restore** — CRIU-based container checkpointing for long-running training jobs. Save GPU state and resume after node maintenance.

6. **Remote execution** — Extend `k8s_job` step type to target remote K3s clusters. Enables burst capacity on cloud GPU instances.

7. **Spack binary cache** — Publish compiled Spack packages to a binary cache. Reduces image build time from hours to minutes for fresh installations.
