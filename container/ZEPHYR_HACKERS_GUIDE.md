# Zephyr Container Infra: Hacker's Guide

Operator guide for running and extending Zephyr container infra without drifting from the v2 contract.

## Core Model (Remember This)

1. Build heavy dependencies once with Spack in builder workflows.
2. Bake those dependencies into snapshot images.
3. Validate new dependency changes in staging before promotion.
4. Layer app packages with uv on top of Spack using constraints/overrides.
5. Promote only after layered verification passes.

Authoritative design contract:
- `container/ZEPHYR_SYSTEM_DESIGN.md`

## Quick Start

```bash
./container/launch_container.sh
./container/launch_container.sh -- bash -lc "echo hello"
./tools/zephyr_job run --project-id zephyr-a --job hello -- "echo hello"
```

## Build Authority and Snapshots

Builder-only Spack operations require:

```bash
export SYGALDRY_BUILD_ROLE=builder
```

Build Spack env (builder flow):

```bash
./tools/zephyr_job run --project-id zephyr-build --job spack-build -- "cd /workspace/pkg/zephyr && ./build.sh"
```

Bake snapshot image after build:

```bash
./container/snapshot_spack.sh
```

Consumer flows should use snapshot images and avoid running Spack install directly.

## Staging a New Spack Spec

Use staging to test concretization/install without mutating production env files:

```bash
./container/launch_container.sh -- \
  bash -lc "tools/zephyr_stage_spack.sh --spec py-soundfile --python-import soundfile"
```

Artifacts:
- `/workspace/outputs/spack_stage/<run_id>/logs/concretize_report.json`
- `/workspace/outputs/spack_stage/<run_id>/logs/new_requirements.txt`
- `/workspace/outputs/spack_stage/<run_id>/logs/final_status.json`

## Hybrid Spack + uv Layering

Install app-level Python packages with uv while preserving Spack ownership:

```bash
SYGALDRY_ENTRYPOINT=uv-install ./container/launch_container.sh -- transformers tokenizers accelerate
```

Layering policy:
- Spack-owned package names: `container/spack_owned_packages.conf`
- NVIDIA pip exclusion: `container/nvidia_overrides.txt`
- Provenance check: `container/verify_uv_spack.py`

## Runtime Layout (v2)

Host root:
- `/mnt/data_infra/zephyr_container_infra/`

Project-scoped paths:
- `/mnt/data_infra/zephyr_container_infra/projects/<project_id>/home`
- `/mnt/data_infra/zephyr_container_infra/projects/<project_id>/workspace`
- `/mnt/data_infra/zephyr_container_infra/projects/<project_id>/outputs`
- `/mnt/data_infra/zephyr_container_infra/projects/<project_id>/runs`
- `/mnt/data_infra/zephyr_container_infra/projects/<project_id>/leases`

Shared caches:
- `/mnt/data_infra/zephyr_container_infra/shared/hf_cache`
- `/mnt/data_infra/zephyr_container_infra/shared/uv_cache`
- `/mnt/data_infra/zephyr_container_infra/shared/bazel_cache`

## Verification Runbook

Fast checks:

```bash
./validate_all.sh --quick
./validate_all.sh --multi-repo-unit
```

Snapshot and UV layering (no GPU):

```bash
./validate_all.sh --snapshot-no-gpu
./validate_all.sh --uv-layering-no-gpu
```

Full GPU validation:

```bash
./validate_all.sh --snapshot
./validate_all.sh --uv-layering
./validate_all.sh --multi-repo
```

Infra pipeline:

```bash
./container/verify_all.sh --smoke
./container/verify_all.sh
```

## Troubleshooting

GPU runtime fails:
- `nvidia-smi`
- `container/diagnose_nvidia.sh`
- `container/inspect_nvidia_setup.sh`
- `container/fix_nvidia_setup.sh`

Dependency layering fails:
- `container/verify_uv_layering.sh`
- `container/verify_uv_spack.py`

Snapshot validity fails:
- `container/verify_snapshot.sh`
