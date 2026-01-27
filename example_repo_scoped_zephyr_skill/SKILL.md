---
name: zephyr-container-infra
description: Repo-scoped spec for consuming the Zephyr Spack snapshot with shared caches, per-project isolation, run-id concurrency, and advisory GPU leases.
---

# Zephyr Container Infrastructure Specification (v2)

## Purpose

Use this skill when running workloads in the Zephyr Spack snapshot image while sharing heavyweight caches across repos and isolating project-local mutable state.

## Required Preconditions

- NVIDIA runtime present: `docker info | grep -i nvidia`
- Host CUDA support for image CUDA 12.9.1: `nvidia-smi`
- Snapshot image available:
  `docker image inspect ghcr.io/phi9t/sygaldry/zephyr:spack`

## Directory Contract

```text
$ZEPHYR_CACHE_ROOT (default: /mnt/data_infra/zephyr_container_infra)
├── shared/
│   ├── hf_cache
│   ├── uv_cache
│   ├── bazel_cache
│   ├── torch_cache
│   ├── triton_cache
│   ├── nv_compute_cache
│   └── jax_cache
├── sygaldry/
│   └── spack_store
└── projects/<project_id>/
    ├── home
    ├── config
    ├── local_share
    ├── outputs
    ├── workspace
    ├── runs
    └── leases
```

## Mount Protocol

- Shared caches:
  - `shared/hf_cache -> /opt/hf_cache`
  - `shared/uv_cache -> /opt/uv_cache`
  - `shared/bazel_cache -> /opt/bazel_cache`
  - `shared/torch_cache -> /opt/torch_cache`
  - `shared/triton_cache -> /opt/triton_cache`
  - `shared/nv_compute_cache -> /opt/nv_compute_cache`
  - `shared/jax_cache -> /opt/jax_cache`
- Per-project state:
  - `projects/<id>/home -> /home/kvothe`
  - `projects/<id>/config -> /home/kvothe/.config`
  - `projects/<id>/local_share -> /home/kvothe/.local/share`
  - `projects/<id>/outputs -> /workspace/outputs`

## Runtime Controls

- `--run-id <id>` or `SYGALDRY_RUN_ID` for per-run isolation.
- `--lease-mode off|warn|enforce` (default `warn`) for GPU lease checks.
- `--cache-profile shared|isolated|hybrid` (default `shared`).
- `--print-effective-config` to print resolved paths and env contract.

## Spack Policy

- Consumer repos use `ghcr.io/phi9t/sygaldry/zephyr:spack`.
- Spack installs/builds are blocked unless:
  - `SYGALDRY_BUILD_ROLE=builder`
- Builder role is reserved for `sygaldry` build workflows.

## Verification Commands

```bash
# Effective path/mount contract
./container/launch_container.sh --print-effective-config -- true

# GPU + framework verification
SYGALDRY_ENTRYPOINT=verify-spack ./container/launch_container.sh

# Shared cache visibility
./container/launch_container.sh -- bash -lc \
  'ls -la /opt/hf_cache /opt/uv_cache /opt/bazel_cache /opt/torch_cache /opt/jax_cache'

# Run with explicit isolation + lease mode
SYGALDRY_PROJECT_ID=myrepo \
./container/launch_container.sh --run-id run-$(date +%s) --lease-mode warn -- python -c 'print("ok")'
```

## Job Runner Notes

`tools/zephyr_job` stores:
- Raw logs: `projects/<id>/runs/<run_id>/raw/`
- JSONL + status: `projects/<id>/outputs/.run-metadata/<run_id>/`

Use `--run-id` to query specific runs with `status`/`tail`.
