# Architecture Overview

Sygaldry has two independent subsystems that can be used separately or together.

```
┌─────────────────────────────────────────────┐
│  Zephyr Container Infrastructure            │
│  Hermetic GPU runtime + multi-repo reuse    │
└─────────────────────────────────────────────┘
┌─────────────────────────────────────────────┐
│  Temporal Workflow Engine                   │
│  Durable YAML DAG execution + observability │
└─────────────────────────────────────────────┘
```

The two subsystems share no code. Temporal can run `container_job` steps that launch
Zephyr containers, but neither depends on the other to function.

## Zephyr: Three-Tier Model

```
Tier 1 — Docker base image
  NVIDIA CUDA 12.9.1 + Ubuntu 24.04
  Container runtime libraries, system tools

Tier 2 — Spack snapshot (baked into image, ~42 GB)
  torch, jax, numpy, scipy, triton, llvmlite, numba
  Pinned in spack.lock; built once, never rebuilt by consumers

Tier 3 — uv app layer (per-project, mounted at runtime)
  transformers, datasets, vllm, outlines, project-specific packages
  Installed on top of Spack without ownership conflicts
```

Spack owns the heavy scientific/ML stack. uv owns application packages. The layering
boundary is enforced by `container/spack_owned_packages.conf` and verified by
`container/verify_uv_layering.sh`.

## Storage Layout

```
$ZEPHYR_CACHE_ROOT/                         (default: /mnt/data_infra/zephyr_container_infra)
├── shared/                                 shared across all projects
│   ├── hf_cache/       → /opt/hf_cache     HuggingFace models/datasets
│   ├── uv_cache/       → /opt/uv_cache     UV download cache
│   ├── bazel_cache/    → /opt/bazel_cache
│   └── ...torch/triton/jax/nv caches
├── sygaldry/                               builder-only
│   └── spack_store/    → /opt/spack_store  42 GB Spack packages + view
└── projects/
    └── <project_id>/                       per-project
        ├── home/        → /home/kvothe
        ├── workspace/   → /workspace       persistent venvs, configs
        └── outputs/     → /workspace/outputs
```

The Spack store is a precious artifact — never move or copy it. Downstream repos share
it via mount (see `docs/ZEPHYR_VENDORING_GUIDE.md`).

## Temporal: Data Flow

```
YAML plan file
    │
    ▼
go run ./cmd/orchestrate run -plan <file>
    │  validates schema, resolves deps, emits workflow
    ▼
Temporal server (localhost:7233)
    │  durable task queue
    ▼
go run ./cmd/worker
    │  executes activities (one per step)
    │  writes stdout/stderr artifacts + JSONL step logs
    ▼
logs/
    │
    ▼
./scripts/logs_cli.py  (CLI)  +  visualizer/server.js  (web UI)
```

The worker executes each step as a Temporal activity. Step outputs emitted via
`::set-output name=key::value` are captured and made available to downstream steps
via `${{ steps.<id>.outputs.<key> }}` interpolation.

## Deep-Dive References

| Document | Content |
|---|---|
| `container/ZEPHYR_SYSTEM_DESIGN.md` | Authoritative Zephyr infra contract (storage, launcher, image modes) |
| `docs/ZEPHYR_VENDORING_GUIDE.md` | Vendoring Zephyr into downstream repos |
| `temporal/TEMPORAL_DESIGN.md` | Temporal design, step types, DAG semantics |
| `temporal/TEMPORAL_ONBOARDING_GUIDE.md` | Temporal onboarding workflow |
| `docs/TEMPORAL_PLAN_SCHEMA.md` | YAML plan field reference |
| `SYSTEM_DESIGN.md` | Top-level system overview |
