# Zephyr Container Infra: Engineering System Design

**Version:** 2.2
**Date:** 2026-02-13
**Status:** Implemented

## Summary

Zephyr v2 standardizes container storage into three roots:

- Shared caches for all repos.
- A builder-only root for Spack builds/snapshots.
- Per-project roots for home/config/outputs/workspace/runs/leases.

Spack builds are restricted to builder role (`SYGALDRY_BUILD_ROLE=builder`) and consumer repos use the Spack-baked snapshot image.

## Core Mental Model (Remember This)

1. Build heavy dependencies once with Spack in builder workflows.
2. Bake the validated Spack environment into snapshot images.
3. Test new dependency changes in staging before promotion.
4. Layer application packages with uv on top of Spack without ownership conflicts.
5. Promote images only after layered verification gates pass.

## Host Layout

```text
/mnt/data_infra/zephyr_container_infra/                 ($ZEPHYR_CACHE_ROOT)
├── shared/                                             ($ZEPHYR_SHARED_ROOT)
│   ├── hf_cache/          -> /opt/hf_cache
│   ├── uv_cache/          -> /opt/uv_cache
│   ├── bazel_cache/       -> /opt/bazel_cache
│   ├── torch_cache/       -> /opt/torch_cache
│   ├── triton_cache/      -> /opt/triton_cache
│   ├── nv_compute_cache/  -> /opt/nv_compute_cache
│   └── jax_cache/         -> /opt/jax_cache
├── sygaldry/                                            ($ZEPHYR_BUILD_ROOT)
│   ├── spack_store/       -> /opt/spack_store (builder only; skipped for baked image)
│   └── ...
├── projects/                                            ($ZEPHYR_PROJECTS_ROOT)
│   └── <project_id>/                                    ($ZEPHYR_PROJECT_ROOT)
│       ├── home/            -> /home/kvothe
│       ├── config/          -> /home/kvothe/.config
│       ├── local_share/     -> /home/kvothe/.local/share
│       ├── outputs/         -> /workspace/outputs
│       ├── workspace/       -> /workspace (multi-repo persistent workspace)
│       ├── runs/
│       └── leases/
└── meta/
    └── layout_version.json
```

## Launcher Contract (`container/launch_container.sh`)

### New/primary env knobs

- `ZEPHYR_CACHE_ROOT` (default `/mnt/data_infra/zephyr_container_infra`)
- `ZEPHYR_SHARED_ROOT` (default `$ZEPHYR_CACHE_ROOT/shared`)
- `ZEPHYR_BUILD_ROOT` (default `${ZEPHYR_CACHE_ROOT}/sygaldry`)
- `ZEPHYR_PROJECTS_ROOT` (default `$ZEPHYR_CACHE_ROOT/projects`)
- `ZEPHYR_PROJECT_ROOT` (default `$ZEPHYR_PROJECTS_ROOT/$SYGALDRY_PROJECT_ID`)
- `SYGALDRY_RUN_ID` (auto-generated if unset)
- `ZEPHYR_LEASE_MODE` (`off|warn|enforce`, default `warn`)
- `ZEPHYR_CACHE_PROFILE` (`shared|isolated|hybrid`, default `shared`)

### Backward compatibility

Legacy overrides are still honored:
- `SYGALDRY_SPACK_STORE`
- `SYGALDRY_HF_CACHE`
- `SYGALDRY_UV_CACHE`

The launcher logs deprecation warnings when these are used.

### New CLI flags

- `--run-id <id>`
- `--lease-mode off|warn|enforce`
- `--cache-profile shared|isolated|hybrid`
- `--print-effective-config`

## Container Env Exports

The launcher injects:

- `SYGALDRY_IN_CONTAINER=1`
- `SYGALDRY_PROJECT_ID`
- `SYGALDRY_RUN_ID`
- `SYGALDRY_ROOT`
- `HF_HOME=/opt/hf_cache`
- `UV_CACHE_DIR=/opt/uv_cache`
- `TORCH_HOME=/opt/torch_cache`
- `TRITON_CACHE_DIR=/opt/triton_cache`
- `CUDA_CACHE_PATH=/opt/nv_compute_cache`
- `JAX_COMPILATION_CACHE_DIR=/opt/jax_cache`
- `XDG_CONFIG_HOME=/home/kvothe/.config`
- `XDG_DATA_HOME=/home/kvothe/.local/share`
- `XDG_CACHE_HOME=/opt/uv_cache`

## Concurrency Model

Run isolation is `project_id + run_id`.

- Per-run metadata/logs are stored under project outputs (`outputs/.run-metadata/<run_id>/...`).
- Launcher creates an advisory GPU lease (`leases/gpu-all.lease`) with TTL.
- Lease behavior:
  - `off`: do not check lease.
  - `warn`: warn on active lease and continue.
  - `enforce`: fail when active lease exists.

## Spack Build Authority

- Consumer flows must use baked images and do not run Spack install.
- `container/entrypoints/spack-build.sh` and `container/entrypoints/spack-install.sh` enforce:
  - `SYGALDRY_BUILD_ROLE=builder` required.
- Staging installs (`tools/zephyr_stage_spack.sh`) are builder-authorized operations intended for controlled dependency evaluation before snapshot promotion.

## UV-Spack Package Layering

The container uses a three-tier package ownership model to prevent package conflicts and ensure reproducibility.

### Package Ownership Tiers

| Tier | Provider | Examples | Authoritative Source |
|------|----------|----------|---------------------|
| CUDA/NVIDIA runtime | Docker base image (`nvidia/cuda:12.9.1`) | libcuda, libcudnn, libnccl | Base image layers |
| Core ML/scientific | Spack (`pkg/zephyr/spack_src.yaml`) | torch, jax, numpy, scipy, triton, scikit-learn | `container/spack_owned_packages.conf` |
| User/application | UV (`uv pip install`) | transformers, vllm, sglang, datasets | Per-project `requirements.txt` |

### Canonical Package List

`container/spack_owned_packages.conf` is the single source of truth for pip package names managed by Spack.  Both `configure_uv_spack()` (bashrc function) and `container/entrypoints/uv-install.sh` read this file dynamically, with a hardcoded fallback if the file is not found.

Current Spack-owned packages: `torch`, `torchvision`, `torchaudio`, `jax`, `jaxlib`, `triton`, `numpy`, `scipy`, `scikit-learn`, `numba`, `llvmlite`, `matplotlib`, `pandas`, `soundfile`, `jupyterlab`.

### NVIDIA Exclusion

`container/nvidia_overrides.txt` is a UV override file that uses the impossible-marker pattern (`sys_platform == 'never'`) to prevent UV from resolving NVIDIA/CUDA pip packages (e.g. `nvidia-cublas-cu12`, `nvidia-cudnn-cu12`).  These are provided by the Docker base image and Spack.

The override file is passed to `uv pip install --override nvidia_overrides.txt` in `uv-install.sh`.

### Enforcement Layers

Three mechanisms work together to prevent UV from overriding Spack packages:

1. **`UV_NO_BUILD_ISOLATION_PACKAGE`** — Prevents UV from rebuilding Spack-owned packages.  Read from `spack_owned_packages.conf`.
2. **Spack constraint file** — `uv-install.sh` generates a constraint file from Spack-installed package versions, pinning them during UV resolution.
3. **NVIDIA override file** — `nvidia_overrides.txt` blocks all `nvidia-*` pip packages from being resolved.

### Verification

- `container/verify_uv_spack.py` — Checks that all Spack-owned packages resolve from `/opt/spack_store/view` and no `nvidia-*` pip packages are installed outside the Spack view.
- `container/verify_uv_layering.sh` — End-to-end test harness (T8 series) that creates a UV venv, installs user packages (transformers, accelerate, etc.), and verifies provenance rules.  Run via `./validate_all.sh --uv-layering`.

## Staged Spack Concretization and Install (Generic Pattern)

This mechanism evaluates a new spec in an isolated staging environment before any production Spack env changes.

### Why staging exists

- Avoid mutating production `spack.yaml`/`spack.lock` during dependency experiments.
- Reuse the shared install tree and caches to minimize redundant work.
- Enforce a hard policy that staged concretization must not require rebuilding Torch/JAX/LLVM core stacks.

### Inputs and isolation boundaries

- Source manifest: any Spack env yaml (default `pkg/zephyr/spack_src.yaml`), copied into staging as `spack.yaml`.
- Staged run root: `outputs/spack_stage/<run_id>/`.
- Reused shared state:
  - `/opt/spack_store/install_tree`
  - `/opt/spack_store/build_cache`
  - `/opt/spack_store/source_cache`
  - `/opt/spack_store/misc_cache`
- Staged-only mutable state:
  - staging env directory (`spack.yaml`, generated `spack.lock`)
  - staging view path
  - staging logs and reports

### Container and mount behavior

- Non-baked flow mounts host Spack store to container:
  - `/mnt/data_infra/zephyr_container_infra/sygaldry/spack_store` -> `/opt/spack_store`
- Baked image flow skips this mount and uses baked Spack content.
- Launcher behavior is implemented in `container/launch_container.sh`.

### Execution flow

1. Launch Zephyr container with `container/launch_container.sh`.
2. Run concretization analysis in staging:
   - `tools/zephyr_concretize_analyze.sh`
   - `tools/zephyr_concretize_analyze.py`
3. Compute missing concretized hashes vs installed hashes in shared install tree.
4. Enforce forbidden-core guard:
   - block if missing set contains `py-torch`, `py-jax`, `py-jaxlib`, `torch`, `jax`, `jaxlib`, or `llvm`
5. If guard passes, continue in staging only:
   - `spack -e <stage_env> install`
   - `spack -e <stage_env> env view regenerate`
   - Authoritative view configuration and container use: `foundation.org`, Pillar 1 (Spack View and P1.7).
6. Verify staged result:
   - `pkg/zephyr/verify.sh --require-gpu`
   - `container/entrypoints/verify-gpu.sh`
   - optional explicit Python imports via `--python-import` arguments

Integrated helper:
- `tools/zephyr_stage_spack.sh`

### Artifacts and operator outputs

- `outputs/spack_stage/<run_id>/logs/concretize_report.json`
- `outputs/spack_stage/<run_id>/logs/new_requirements.txt`
- `outputs/spack_stage/<run_id>/logs/final_status.json`

These files are the canonical record for whether a staged attempt is safe to proceed.

### Known failure mode under current policy

- A staged concretization may resolve to a missing `llvm` hash even when Torch/JAX are present.
- In this case the guard fails by design, install does not proceed, and production env files remain unchanged.

## Job Runner (`tools/zephyr_job`)

- Uses `projects/<id>/runs/<run_id>/raw` for host raw logs.
- Uses `projects/<id>/outputs/.run-metadata/<run_id>` for JSONL + status.
- Forwards `SYGALDRY_RUN_ID` and `ZEPHYR_LEASE_MODE` to launcher.

## Governance and Source of Truth

- Authoritative infra contract: `container/ZEPHYR_SYSTEM_DESIGN.md` (this document).
- Legacy design pointer retained for compatibility: `container/ZEPHYR_UNIFIED_CACHE_SYSTEM_DESIGN.md` (deprecated).
- Root architecture overview: `SYSTEM_DESIGN.md` (high-level only; non-authoritative for infra defaults/contracts).
- Anti-drift contract checks: `tools/check_zephyr_contracts.sh` (invoked by `validate_all.sh`).

## Verification and Validation

### Test Layers

The verification infrastructure is organized into layers of increasing cost. Each layer has different prerequisites and can run independently.

| Layer | Script(s) | Prerequisites | Speed | What it validates |
|-------|-----------|--------------|-------|-------------------|
| L0: Syntax | `bash -n`, `shellcheck`, `python -m py_compile` | None | seconds | Shell/Python parse correctness |
| L1: Unit (no Docker) | `launch_container_test.sh` | None | seconds | Launcher arg parsing, config resolution, docker arg generation |
| L2: Go | `go test ./...` (temporal/) | Go toolchain | ~10s | Orchestration plan validation, activities, workflows (89 tests) |
| L3: Python lint | `ruff`, `black`, `pytest` | `.venv-lint` | ~5s | Style, formatting, host-side Python tests |
| L4: Integration (Docker, no GPU) | `verify_multi_repo.sh` | Docker + base image | ~30s | Legacy/multi-repo mount layout, env vars, Spack store integrity |
| L5: Snapshot (Docker, optional GPU) | `verify_snapshot.sh` | Docker + snapshot image | ~60s | Baked image self-containment (T1-T7) |
| L6: UV layering (Docker, optional GPU) | `verify_uv_layering.sh` | Docker + snapshot image | ~120s | UV+Spack package provenance, NVIDIA exclusion (T8.1-T8.5 baseline; T8.6/T8.8 optional serving profile) |
| L7: E2E (Docker + GPU) | `verify_multi_repo_e2e.sh` | Docker + GPU + base image + Spack store | ~120s | GPU from external repo, workspace isolation/persistence |
| L8: Infra full (Docker + GPU) | `verify_all.sh` | Docker + GPU + base image + Spack store | ~30min | Preflight, image build, Spack install, ML validation, uv, logs |

### Test ID Registry

| ID | Layer | Script | Description |
|----|-------|--------|-------------|
| T1 | L5 | `verify_snapshot.sh` | Image metadata — labels, ENV vars |
| T2 | L5 | `verify_snapshot.sh` | Filesystem structure — view symlink, spack.yaml, entrypoints, .spack-db |
| T3 | L5 | `verify_snapshot.sh` | Python imports (no GPU) — torch, jax, numpy, scipy |
| T4 | L5 | `verify_snapshot.sh` | Spack env activation — `spack env activate`, `spack find` |
| T5 | L5 | `verify_snapshot.sh` | GPU validation — `torch.cuda.is_available()`, JAX GPU devices, matmul |
| T6 | L5 | `verify_snapshot.sh` | Launcher integration — baked image with `run-job` entrypoint |
| T7 | L5 | `verify_snapshot.sh` | No spack_store shadowing — baked content visible without host mount |
| T8.1 | L6 | `verify_uv_layering.sh` | UV venv creation — uv-install.sh with transformers/tokenizers/accelerate |
| T8.2 | L6 | `verify_uv_layering.sh` | Spack provenance — core packages (torch, jax, numpy, etc.) from `/opt/spack_store/view` |
| T8.3 | L6 | `verify_uv_layering.sh` | UV provenance — user packages (transformers, tokenizers, etc.) from `.venv` |
| T8.4 | L6 | `verify_uv_layering.sh` | No NVIDIA pip packages — no `nvidia-*` packages installed by UV |
| T8.5 | L6 | `verify_uv_layering.sh` | GPU functional — torch CUDA matmul + HF tokenizer load after UV layering |
| T8.6 | L6 | `verify_uv_layering.sh` | vllm install + provenance + functional checks — optional (`--with-vllm`) |
| T8.7 | L6 | `verify_uv_layering.sh` | datasets install in separate venv — non-blocking warning-only check |
| T8.8 | L6 | `verify_uv_layering.sh` | sglang install + provenance + functional checks — optional (`--with-vllm`) |

### Release Gates

- Baseline snapshot validity requires passing T1-T5 and T7.
- Baseline hybrid layering validity requires passing T8.1-T8.5.
- T8.7 is informational (warning-only) and does not block baseline snapshot promotion.
- T8.6 and T8.8 are serving-profile checks (`--with-vllm`); treat as blocking only for serving-ready labels.

### CI Orchestrator: `validate_all.sh`

The top-level CI script runs layers selectively via flags. Default invocation (no flags) runs L0-L3.

| Flag | Layers run | Prerequisites |
|------|-----------|--------------|
| *(none)* | L0 (shellcheck) + L2 (Go) + L3 (Python lint) | Go, `.venv-lint`, shellcheck |
| `--quick` | L2 (Go) + L3 (Python lint), skip shellcheck | Go, `.venv-lint` |
| `--verify-only` | Spack verify only (`verify-spack.sh` entrypoint) | Docker + GPU |
| `--multi-repo-unit` | L1 (launcher unit tests) | None |
| `--multi-repo` | L1 + L4 + L7 (unit + integration + E2E) | Docker + GPU + base image |
| `--snapshot` | L5 (T1-T7) | Docker + GPU + snapshot image |
| `--snapshot-no-gpu` | L5 (T1-T4, T7) | Docker + snapshot image |
| `--uv-layering` | L6 (T8.1-T8.5) | Docker + GPU + snapshot image |
| `--uv-layering-no-gpu` | L6 (T8.1-T8.4) | Docker + snapshot image |
| `--infra` | L8 smoke (preflight + image verify) | Docker + GPU |
| `--infra-full` | L8 full (preflight + build + Spack install + epilogue) | Docker + GPU + Spack store |

### Infra Verification Pipeline: `verify_all.sh`

The full infra verification pipeline (`container/verify_all.sh`) chains four stages:

| Step | Script | What it does |
|------|--------|-------------|
| 0: Preflight | `verify_preflight.sh` | Docker check, storage layout, host GPU diagnostics (`diagnose_nvidia.sh`), container GPU check (`verify-gpu.sh` entrypoint) |
| 1: Image build | `verify_image_build.sh` | Build/verify base Docker image (auto/always/never policy) |
| 2: Spack install | `verify_build.sh` | Run `zephyr_autobuild.sh` or `zephyr_autoretry.sh` for Spack env |
| 3: Epilogue | `verify_epilogue.sh` | ML validation (torch/jax), uv install test, UV-Spack provenance (`verify_uv_spack.py`), job status/log checks |

Flags: `--smoke` skips steps 2-3. `--skip-spack` skips step 2 only. `--skip-uv` skips uv in step 3.

### Container Entrypoint Verifiers

These run *inside* the container (invoked via `launch_container.sh --entrypoint`):

| Entrypoint | What it checks |
|------------|---------------|
| `verify-gpu.sh` | nvidia-smi, CUDA toolkit, PyTorch CUDA availability, JAX GPU devices |
| `verify-spack.sh` | Spack view exists, torch/jax importable, tensor matmul on GPU, NN forward+backward on GPU |

### Python Verification Scripts

| Script | What it checks |
|--------|---------------|
| `verify_uv_spack.py` | All Spack-owned packages resolve from `/opt/spack_store/view`; no `nvidia-*` pip packages outside Spack view |

### Validation Runbook

**Developer pre-commit (fast, no Docker):**
```bash
./validate_all.sh --quick           # Go + Python lint (~15s)
./validate_all.sh --multi-repo-unit # Launcher unit tests (~5s)
```

**Post image change (Docker, no GPU):**
```bash
./validate_all.sh --snapshot-no-gpu    # T1-T4, T7
./validate_all.sh --uv-layering-no-gpu # T8.1-T8.4
```

**Full GPU validation:**
```bash
./validate_all.sh --snapshot         # T1-T7 (snapshot image, GPU)
./validate_all.sh --uv-layering      # T8.1-T8.5 (UV layering, GPU)
./validate_all.sh --multi-repo       # Multi-repo unit + integration + E2E
```

**Full infrastructure validation (Spack build + ML + uv):**
```bash
./container/verify_all.sh            # All stages (30+ min)
./container/verify_all.sh --smoke    # Preflight + image only
```

**Syntax check all scripts:**
```bash
bash -n container/launch_container.sh
bash -n tools/zephyr_job
bash -n container/verify_uv_layering.sh
bash -n container/verify_snapshot.sh
```
