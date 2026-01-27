# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Sygaldry is a Docker + Spack mono-repo build system for reproducible, hermetic builds with GPU/CUDA support for Python, C++, and Rust with scientific computing dependencies. It includes a Temporal-based workflow orchestration system.

**Important:** This is a **GPU-only** container infrastructure. NVIDIA Docker runtime is required.

**Two-Tier Architecture:**
- **Docker**: Environment isolation (NVIDIA CUDA 12.9.1 base image, container user `kvothe` maps to host UID/GID)
- **Spack**: HPC/scientific library management (NumPy, PyTorch, JAX, MPI, CUDA, cuDNN, etc.)

## Quick Start

```bash
# Launch development container (auto-builds image if needed)
./container/launch_container.sh

# Inside container: activate Spack environment
spack-env-activate

# Verify GPU
gpu-test   # PyTorch CUDA check
jax-test   # JAX GPU check
```

## Multi-Repo Usage (General Skill)

Sygaldry can be used as a shared GPU container skill by other codebases on the host.
The `--repo` flag mounts an external repo into the container while reusing the shared
Spack environment (pkg/zephyr), UV cache, and HF cache.

**Install the CLI wrapper (one-time):**
```bash
ln -s /mnt/data_infra/workspace/sygaldry/bin/sygaldry /usr/local/bin/sygaldry
```

**Use from any repo:**
```bash
cd /path/to/my-ml-project
sygaldry --repo .                              # Interactive shell
sygaldry --repo . -- python train.py           # Run a command
sygaldry --repo . --entrypoint verify-gpu.sh   # Verify GPU
sygaldry --repo /path/to/other-project         # Explicit repo path
```

**How it works:**
- Sygaldry mounts read-only at `/opt/sygaldry` (entrypoints + pkg/zephyr)
- External repo mounts at `/workspace/<repo_name>`
- `/workspace` is a persistent host dir per project (venvs, .env, configs survive restarts)
- Spack store, UV cache, HF cache are **shared** from the sygaldry project's existing stores
- UV venvs are per-project (created under `/workspace`)

**CRITICAL:** The 42GB Spack store (`spack_store/`) is a precious artifact containing
JAX + Torch + CUDA. It is never moved or copied. New projects share it by mounting the
same host directory at `/opt/spack_store`.

**Customization env vars for shared resources:**
```bash
SYGALDRY_SPACK_STORE=/path/to/spack_store   # Override shared Spack store
SYGALDRY_UV_CACHE=/path/to/uv_cache         # Override shared UV download cache
SYGALDRY_HF_CACHE=/path/to/hf_cache         # Override shared HF cache
SYGALDRY_PROJECT_ID=my-project              # Per-project isolation namespace
```

## Commands

**Container management (legacy -- sygaldry at /workspace):**
```bash
./container/launch_container.sh                    # Interactive shell
./container/launch_container.sh --entrypoint run-job.sh -- "python train.py"
./container/launch_container.sh --entrypoint verify-gpu.sh  # GPU verification
./container/launch_container.sh --entrypoint hf-download.sh -- model Qwen/Qwen3-0.6B-Base
```

**Spack environments:**
```bash
cd pkg/zephyr && ./build.sh      # Build Zephyr CUDA environment
spack-env-activate               # Activate current directory's env
spack --env . find               # List installed packages
```

**Python (uv):**
```bash
uv venv                    # Create virtual environment
source .venv/bin/activate  # Activate venv
uv pip install <package>   # Install package (always use uv pip, never pip directly)
```

**GPU Verification:**
```bash
gpu-test    # Quick PyTorch CUDA check
jax-test    # Quick JAX GPU check
./container/launch_container.sh --entrypoint verify-gpu.sh    # Full verification
./container/launch_container.sh --entrypoint verify-spack.sh  # Fast Spack verification (no rebuild)
```

**Validation:**
```bash
./validate_all.sh               # Run all checks (go build/vet/test, ruff, black, shellcheck, pytest)
./validate_all.sh --quick       # Skip shellcheck
./validate_all.sh --verify-only # Quick Spack/GPU verification only (no rebuild)
```

**Automated Spack builds with retry:**
```bash
tools/zephyr_autobuild.sh       # One-shot Spack build with GPU validation
tools/zephyr_autoretry.sh       # Retry loop around autobuild with remediation
tools/zephyr_autoretry_tmux.sh  # tmux wrapper for long-running builds
```

## Temporal Orchestration

The `temporal/` directory contains a Go-based workflow orchestration system for running pipelines.

**Start local Temporal:**
```bash
cd temporal
./scripts/start-temporal.sh    # Uses temporal CLI dev server (UI at localhost:8233)
# OR
docker compose up              # Uses Docker (UI at localhost:8080)
```

**Run worker and execute pipelines:**
```bash
# Terminal 1: Start worker
TEMPORAL_ADDRESS=localhost:7233 TEMPORAL_NAMESPACE=default TEMPORAL_TASK_QUEUE=orchestration go run ./cmd/worker

# Terminal 2: Execute a YAML plan
go run ./cmd/orchestrate -plan examples/pipeline.yaml
```

**Inspect logs:**
```bash
./scripts/logs_cli.py list-runs
./scripts/logs_cli.py show-steps --workflow-id <id> --run-id <run>
./scripts/logs_cli.py follow --workflow-id <id> --run-id <run>
```

**Temporal code structure:**
- `cmd/worker/` - Worker process
- `cmd/orchestrate/` - CLI to execute YAML plans (with plan validation)
- `cmd/run/` - Job runner
- `internal/activities/` - Activity implementations (8 step types)
- `internal/workflows/pipeline.go` - Pipeline workflow with dependency resolution
- `examples/` - YAML pipeline definitions
- `scripts/` - Utility and test scripts
- `visualizer/` - Web-based pipeline visualizer (Node.js)

**YAML plan step types:**
- `command` - Run arbitrary shell commands
- `download` - Download files with optional SHA256 verification
- `docker_build` - Build Docker images
- `docker_push` - Push Docker images to registry
- `package_build` - Run package build commands
- `container_job` - Run commands inside Sygaldry containers
- `hf_download_dataset` - Download HuggingFace datasets
- `hf_download_model` - Download HuggingFace models

**Example pipeline with new step types:**
```yaml
steps:
  - id: download-model
    type: hf_download_model
    hf_download_model:
      model_id: Qwen/Qwen3-0.6B-Base

  - id: train
    type: container_job
    depends_on: [download-model]
    container_job:
      project_id: my-project
      entrypoint: run-job.sh
      command: "python train.py --epochs 10"
      gpu: true
    timeout_seconds: 86400
```

## Host-Side Job Runner

The `tools/zephyr_job` CLI manages container jobs from the host:

```bash
tools/zephyr_job run    --project-id <id> --job <name> -- <command>
tools/zephyr_job status --project-id <id> --job <name>
tools/zephyr_job tail   --project-id <id> --job <name> [--lines N]
tools/zephyr_job stop   --project-id <id> --job <name>
tools/zephyr_job health --project-id <id> --job <name>
```

Jobs produce JSONL logs and status files under `/mnt/data_infra/zephyr_container_infra/<id>/`.

## Skills

Repo-scoped skills in `skills/` (do not install globally until validated):

- **zephyr** - Run GPU containers, build MLSys envs, vendor hermetic kits, LLM experiments
- **codex-headless** - Invoke OpenAI Codex CLI in headless (`exec`) mode

## Architecture

**Legacy mode** (sygaldry at /workspace):
```
Host: /mnt/data_infra/zephyr_container_infra/<project_id>/
 ├─ monorepo_home/  → /home/kvothe (container home)
 ├─ spack_store/    → /opt/spack_store (packages + view, 42GB, shared)
 ├─ bazel_cache/    → /opt/bazel_cache
 ├─ hf_cache/       → /opt/hf_cache (HuggingFace models/datasets, shared)
 └─ config/         → configuration files
Sygaldry repo      → /workspace
```

**Multi-repo mode** (`--repo /path/to/other-repo`):
```
Host: /mnt/data_infra/zephyr_container_infra/<project_id>/
 ├─ monorepo_home/  → /home/kvothe (per-project)
 ├─ workspace/      → /workspace (persistent, per-project venvs/configs)
 ├─ bazel_cache/    → /opt/bazel_cache (per-project)
 └─ config/
Shared from sygaldry project:
 ├─ spack_store/    → /opt/spack_store (42GB, NEVER move/copy)
 ├─ hf_cache/       → /opt/hf_cache
 └─ uv_cache/       → /opt/uv_cache
Sygaldry repo      → /opt/sygaldry (read-only)
External repo      → /workspace/<repo_name> (workdir)
```

Container user `kvothe` is created with host UID/GID for seamless file permissions.
Spack is baked into the image at `/opt/spack_src` (no host mount).

## Repository Structure

```
bin/
  sygaldry                     # Host-side CLI wrapper (symlink to /usr/local/bin)
container/
  launch_container.sh          # Primary entry point (legacy + multi-repo modes)
  dev_container.dockerfile     # NVIDIA CUDA 12.9.1 + Ubuntu 24.04 base
  setup_user_environment.sh    # Rust, uv, bashrc configuration
  diagnose_nvidia.sh           # NVIDIA diagnostics and repair
  entrypoints/                 # Container entrypoint scripts
temporal/
  cmd/orchestrate/             # YAML plan executor
  cmd/worker/                  # Temporal worker
  cmd/run/                     # Job runner
  internal/activities/         # Activity implementations
  internal/workflows/          # Pipeline workflow engine
  examples/                    # YAML pipeline examples
  scripts/                     # Utility and test scripts
  visualizer/                  # Web-based pipeline visualizer
tools/
  build.sh                     # Builds base Spack environment
  zephyr_job                   # Host-side job runner CLI
  zephyr_autobuild.sh          # One-shot Spack build with GPU validation
pkg/
  zephyr/                      # Primary AI/ML Spack environment (PyTorch, JAX, CUDA)
skills/
  zephyr/                      # Unified GPU container, MLSys env, adaptation skill
  codex-headless/              # Codex CLI headless skill
```

## Spack Environment Pattern

Each environment uses a `spack_src.yaml` template:

1. `build.sh` copies `spack_src.yaml` → `spack.yaml` if needed
2. Uses `spack.lock` when present (no reconcretize)
3. Runs `spack --env . install`
4. Generates view at `/opt/spack_store/view`

**Creating a new environment:**
```bash
mkdir -p pkg/my_env
cp tools/spack_src.yaml pkg/my_env/spack_src.yaml
cp tools/build.sh pkg/my_env/build.sh
# Edit spack_src.yaml specs section
```

## Entrypoints

Available entrypoints in `container/entrypoints/`:

| Entrypoint | Purpose |
|------------|---------|
| `default.sh` | Interactive shell with GPU validation |
| `run-job.sh` | Run commands with Spack/CUDA setup |
| `verify-gpu.sh` | Verify GPU availability (PyTorch, JAX) |
| `verify-spack.sh` | Fast Spack verification (no rebuild) |
| `hf-download.sh` | Download HF datasets/models |
| `uv-install.sh` | Install Python packages with uv |
| `spack-install.sh` | Run Spack environment install |
| `spack-build.sh` | Build Zephyr Spack environment |

## Shell Script Conventions

Standard header:
```bash
#!/bin/bash
set -eu -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
```

Logging with line numbers:
```bash
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [script:${BASH_LINENO[0]}] $*" >&2
}
```

Note: Always separate `declare`/`readonly`/`local` from command substitution assignment (ShellCheck SC2155).

## Environment Variables

**Launcher customization (current — `ZEPHYR_*` namespace):**
- `ZEPHYR_CACHE_ROOT` - Host root for all container data (default: `/mnt/data_infra/zephyr_container_infra`)
- `ZEPHYR_SHARED_SPACK_STORE` - Shared Spack store path (default: `<cache_root>/sygaldry/spack_store`)
- `ZEPHYR_SHARED_HF_CACHE` - Shared HuggingFace cache path
- `ZEPHYR_SHARED_UV_CACHE` - Shared UV download cache path
- `ZEPHYR_PROJECTS_ROOT` - Per-project root (default: `<cache_root>/projects`)
- `ZEPHYR_SNAPSHOT_REF` - Digest-pinned snapshot ref for validation scripts
- `SYGALDRY_PROJECT_ID` - Project isolation namespace
- `SYGALDRY_IMAGE` - Custom Docker image name (default `sygaldry/zephyr:base`)
- `SYGALDRY_HOME` - Sygaldry repo root (auto-detected from script location)

**Deprecated `SYGALDRY_*` cache vars (still accepted; emit deprecation warnings):**
Use `ZEPHYR_SHARED_*` equivalents above instead.
- `SYGALDRY_SPACK_STORE` → prefer `ZEPHYR_SHARED_SPACK_STORE`
- `SYGALDRY_UV_CACHE` → prefer `ZEPHYR_SHARED_UV_CACHE`
- `SYGALDRY_HF_CACHE` → prefer `ZEPHYR_SHARED_HF_CACHE`

Note: GPU is always required. This is a GPU-only container infrastructure.

**Version control:**
- `PYTHON_VERSION=3.13`
- `RUST_VERSION=1.79.0`

**Temporal:**
- `TEMPORAL_ADDRESS` - Temporal server address (default: localhost:7233)
- `TEMPORAL_NAMESPACE` - Namespace (default: default)
- `TEMPORAL_TASK_QUEUE` - Task queue name (default: orchestration)
- `TEMPORAL_LOG_DIR` - Log directory (default: ./logs)
- `TEMPORAL_LOG_MAX_BYTES` - Max bytes for stdout/stderr in payloads (default: 10000)

**HuggingFace:**
- `HF_HOME` - HuggingFace cache directory (default: /opt/hf_cache)
- `HF_TOKEN` - Token for gated models/datasets

## Container Paths

| Host Path | Container Path | Purpose | Scope |
|-----------|---------------|---------|-------|
| `<id>/monorepo_home` | `/home/kvothe` | User home | per-project |
| `sygaldry/spack_store` | `/opt/spack_store` | Spack packages (42GB) | shared |
| `<id>/bazel_cache` | `/opt/bazel_cache` | Bazel build cache | per-project |
| `sygaldry/hf_cache` | `/opt/hf_cache` | HuggingFace cache | shared |
| `sygaldry/bazel_cache/uv_cache` | `/opt/uv_cache` | UV download cache | shared |
| `<id>/workspace` | `/workspace` | Persistent workspace | per-project (multi-repo) |
| Sygaldry repo | `/opt/sygaldry` | Entrypoints + pkg/zephyr | shared (multi-repo, ro) |
| External repo | `/workspace/<repo_name>` | Working directory | per-project (multi-repo) |
| Project root | `/workspace` | Working directory | legacy mode |

Host paths are relative to `/mnt/data_infra/zephyr_container_infra/`.

## Testing and Validation

**Go tests (89 test cases):**
```bash
cd temporal && go test ./...
```

Test coverage includes:
- `cmd/orchestrate/` - Plan validation (types, deps, when-clauses, required fields)
- `internal/activities/` - Command execution, log writers, input validation, truncation
- `internal/workflows/` - Dependency resolution, skip logic, ordering, step naming

**Python linting:**
```bash
# Requires .venv-lint (create with: uv venv .venv-lint && .venv-lint/bin/pip install ruff black)
.venv-lint/bin/ruff check .
.venv-lint/bin/black --check .
```

**Shell linting:**
```bash
shellcheck -s bash -S warning scripts/*.sh
```

## Key Files

- `container/launch_container.sh` - Primary entry point
- `container/dev_container.dockerfile` - Base image definition (NVIDIA CUDA 12.9.1 + Ubuntu 24.04)
- `container/entrypoints/` - Entrypoint scripts
- `pkg/zephyr/spack_src.yaml` - Zephyr environment specs (PyTorch, JAX with CUDA)
- `pkg/zephyr/spack.lock` - Pinned dependency graph
- `temporal/` - Temporal orchestration system
- `tools/zephyr_job` - Host-side job runner CLI
- `skills/` - Repo-scoped skills (do not install globally until validated)
- `validate_all.sh` - CI validation script (go, ruff, black, shellcheck)
- `SYSTEM_DESIGN.md` - Comprehensive system architecture document

## Troubleshooting

- NVIDIA issues: `container/NVIDIA_FIXES.md`, `container/diagnose_nvidia.sh`
- Container design: `container/ZEPHYR_SYSTEM_DESIGN.md`, `container/ZEPHYR_HACKERS_GUIDE.md`
- System architecture: `SYSTEM_DESIGN.md`
