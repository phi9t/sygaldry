# Getting Started with Sygaldry

Sygaldry has two independent subsystems: **Zephyr**, a hermetic GPU container runtime that
bakes the full ML/scientific stack (PyTorch, JAX, CUDA) into a snapshot image; and **Temporal**,
a durable YAML DAG orchestrator for running multi-step ML pipelines with retries, conditionals,
and structured logs. Both subsystems can be used independently or together.

## Hard Requirements

> **GPU-only infrastructure.** There is no CPU-only mode.

- Linux host (Ubuntu 22.04+ recommended — no WSL2, no macOS)
- NVIDIA GPU with drivers installed
- Docker with NVIDIA Container Toolkit
- ~60 GB free disk space (Spack snapshot ~42 GB + Docker layers + HF cache)
- Go 1.23+ (for Temporal)

## 1) Verify Your Host

```bash
nvidia-smi                          # must succeed
docker info | grep -i nvidia        # must show nvidia runtime
docker run --rm --gpus all nvidia/cuda:12.9.1-base-ubuntu24.04 nvidia-smi
```

If any of these fail, see [DEPLOYMENT.md](DEPLOYMENT.md) for setup instructions.

## 2) Clone and Launch the Container

```bash
git clone https://github.com/phi9t/sygaldry.git
cd sygaldry
./container/launch_container.sh
```

Inside the container:

```bash
spack-env-activate   # activate the Zephyr Spack environment
gpu-test             # PyTorch CUDA sanity check
jax-test             # JAX GPU sanity check
```

## 3) Run Your First Temporal Pipeline

```bash
cd temporal
./scripts/run.sh examples/quickstart/01_hello.yaml
```

Then try the progressive quickstart examples:

```bash
./scripts/run.sh examples/quickstart/02_chain.yaml
./scripts/run.sh examples/quickstart/03_outputs.yaml
```

Full quickstart guide: `temporal/examples/quickstart/QUICKSTART.md`

## What Next

| Document | Purpose |
|---|---|
| [DEPLOYMENT.md](DEPLOYMENT.md) | Fresh-machine setup (drivers, Docker, Go) |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Common failure modes |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the two subsystems fit together |
| [docs/ONBOARDING.md](docs/ONBOARDING.md) | Deeper onboarding for contributors |
| [docs/ZEPHYR_VENDORING_GUIDE.md](docs/ZEPHYR_VENDORING_GUIDE.md) | Use Zephyr in another repo |
| [docs/TEMPORAL_PLAN_SCHEMA.md](docs/TEMPORAL_PLAN_SCHEMA.md) | YAML plan field reference |
