# Sygaldry Onboarding

Audience: engineers onboarding to Zephyr container infra and Temporal orchestration.

This document is an execution-focused onboarding path. Deep contracts live in subsystem canonical docs.

## 1) What You Are Working With

Sygaldry has two core subsystems:

- Zephyr container infrastructure: hermetic GPU runtime and multi-repo container reuse.
- Temporal workflow engine: durable YAML DAG orchestration with logs and status APIs.

Core dependency policy:

1. Spack owns heavy ML/scientific dependencies (torch, jax, llvm-class stack).
2. uv installs app-layer dependencies on top.
3. Consumer repos do not rebuild Spack.

## 2) Prerequisites

- Linux host (Ubuntu 22.04+ recommended)
- NVIDIA GPU and recent drivers
- Docker with NVIDIA runtime
- Go 1.23+
- Node.js (optional, only for visualizer)

Quick host checks:

```bash
nvidia-smi
docker info | grep -i nvidia
```

Optional CLI symlink:

```bash
ln -s /path/to/sygaldry/bin/sygaldry /usr/local/bin/sygaldry  # replace with your actual clone path
```

## 3) First 30 Minutes

### A) Zephyr container sanity

```bash
./container/launch_container.sh
# inside container
spack-env-activate
gpu-test
jax-test
```

### B) Temporal first pipeline

```bash
cd temporal
./scripts/run.sh examples/quickstart/01_hello.yaml
```

Then try:

```bash
./scripts/run.sh examples/quickstart/02_chain.yaml
./scripts/run.sh examples/quickstart/03_outputs.yaml
```

Quickstart reference: `temporal/examples/quickstart/QUICKSTART.md`.

## 4) Zephyr Operational Model

### Package ownership

| Tier | Owner | Examples |
|------|-------|----------|
| Runtime | Docker base image | CUDA/NVIDIA runtime libs |
| Core stack | Spack | torch, jax, numpy, scipy, triton |
| App layer | uv | transformers, datasets, vllm, tools |

### Why this matters

- Spack layer is expensive to build and must stay stable.
- uv gives repo-level agility without breaking the base ML stack.
- Verification scripts enforce provenance and layering rules.

### Multi-repo use

```bash
sygaldry --repo /path/to/my-project
sygaldry --repo /path/to/my-project -- python train.py
```

### Vendoring into a downstream repo

```bash
tools/zephyr_vendor_infra.sh install \
  --target-repo /path/to/target-repo \
  --snapshot-image ghcr.io/phi9t/sygaldry/zephyr:spack-YYYYMMDD \
  --snapshot-digest <64-hex-digest>
```

In target repo:

```bash
.sygaldry/zephyr/bin/repoctl config show
.sygaldry/zephyr/bin/repoctl verify spack
.sygaldry/zephyr/bin/repoctl verify uv-layering --no-gpu
```

## 5) Temporal Operational Model

### CLI contract

```bash
go run ./cmd/orchestrate run -plan <plan.yaml> [-async] [-output yaml|json] [-set k=v]
go run ./cmd/orchestrate validate -plan <plan.yaml>
go run ./cmd/orchestrate status -workflow-id <id> [-run-id <id>] [-output yaml|json]
```

### Supported step types

- `command`
- `download`
- `docker_build`
- `docker_push`
- `package_build`
- `container_job`
- `hf_download_dataset`
- `hf_download_model`

### Key runtime features

- `depends_on` DAG scheduling
- `when` conditions and `allow_failure`
- plan `params`/`env`
- step outputs via `::set-output name=<key>::<value>`
- interpolation with `${{ params.* }}`, `${{ env.* }}`, `${{ steps.<id>.outputs.<key> }}`

### Observability

```bash
./scripts/logs_cli.py list-runs
./scripts/logs_cli.py summary --latest
./scripts/logs_cli.py show-steps --latest
./scripts/logs_cli.py dag --latest
```

Visualizer:

```bash
node visualizer/server.js
# http://localhost:8787
```

## 6) Daily Development Commands

### Zephyr and repo checks

```bash
./validate_all.sh --quick
./validate_all.sh --quality-all
```

### Temporal checks

```bash
cd temporal
go vet ./...
go test ./...
./scripts/test-e2e.sh
```

### Optional heavier Temporal suites

```bash
./scripts/e2e/run_medium.sh
./scripts/e2e/run_heavy.sh
```

### Strict quality gate (CI/release)

```bash
./validate_all.sh --quality-all --quality-strict
```

## 7) Release-Prep Flow

Use this sequence before a release cut:

1. Update docs and contracts first.
2. Run repo baseline validation.
3. Run Temporal vet/test/smoke e2e.
4. Validate Zephyr vendoring kit with `install/update/check` flow on a fixture repo.
5. Confirm release notes/checklist are updated.

Release references:

- `docs/RELEASE_CHECKLIST.md`
- `docs/RELEASE_NOTES_2026-02.md`
- `docs/internal/RELEASE_READINESS_REVIEW_2026-02.md` (maintainer-internal)

## 8) Canonical Docs

- Zephyr infra contract: `container/ZEPHYR_SYSTEM_DESIGN.md`
- Zephyr vendoring manual: `docs/ZEPHYR_VENDORING_GUIDE.md`
- Portable kit reference: `portable/zephyr-container-infra/README.md`
- Temporal canonical design: `temporal/TEMPORAL_DESIGN.md`
- Temporal onboarding: `temporal/TEMPORAL_ONBOARDING_GUIDE.md`

## 9) Guardrails

- Follow `AGENTS.md` for shell, Python, and Go conventions.
- Use `uv venv` and `uv pip install` (never system pip installs).
- Treat Spack-installed packages as constraints in Python venvs.
- Run `go vet ./...` and `go test ./...` in `temporal/` before commit.
- Run `shellcheck -s bash -S warning` where available.
