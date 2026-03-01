# Troubleshooting

This is the central entry point for diagnosing common Sygaldry failures.

## NVIDIA / GPU Issues

**Symptom:** `nvidia-smi` fails, CUDA not found inside container, or GPU not visible.

```bash
# Run the diagnostic script (outputs a full report)
container/diagnose_nvidia.sh

# Inside container
gpu-test     # PyTorch CUDA check
jax-test     # JAX GPU check
```

Reference: `container/NVIDIA_FIXES.md` — documents known NVIDIA runtime issues and fixes.

## Docker Daemon Issues

**Symptom:** `docker: permission denied` or `Cannot connect to the Docker daemon`.

```bash
# Check daemon status
sudo systemctl status docker

# Re-add your user to the docker group (requires logout/login)
sudo usermod -aG docker $USER
newgrp docker

# Test
docker info | grep -i nvidia
```

## Spack Environment Issues

**Symptom:** `spack-env-activate` fails, packages missing, or container errors about
the Spack view.

```bash
# Fast Spack verification (no rebuild)
./container/launch_container.sh --entrypoint verify-spack.sh
```

If the snapshot image is missing, pull it:

```bash
docker pull ghcr.io/phi9t/sygaldry/zephyr:spack-20260212-082355
```

See `docs/RELEASE_NOTES_2026-02.md` for the current validated image tag.

## uv / Python Layering Conflicts

**Symptom:** `pip install` or `uv pip install` installs a conflicting version of torch,
numpy, jax, or another Spack-owned package.

```bash
# Check which packages Spack owns (do not reinstall these with uv)
cat container/spack_owned_packages.conf

# Check NVIDIA wheel overrides (use these instead of generic PyPI packages)
cat container/nvidia_overrides.txt

# Run layering verification
./container/verify_uv_layering.sh
```

Rule: Spack owns torch, jax, numpy, scipy, triton, and llvm-class packages.
uv installs only the app layer on top.

## Temporal Issues

**Symptom:** `./scripts/run.sh` hangs or fails with connection errors.

```bash
# Ensure the Temporal dev server is running (no Postgres required)
cd temporal && ./scripts/start-temporal.sh

# Or with Docker Compose (requires Postgres)
docker compose up
```

**Symptom:** Worker not processing tasks.

```bash
# Start the worker in a separate terminal
cd temporal
TEMPORAL_ADDRESS=localhost:7233 TEMPORAL_NAMESPACE=default \
  TEMPORAL_TASK_QUEUE=orchestration go run ./cmd/worker
```

**Symptom:** A step failed and you need to inspect logs.

```bash
cd temporal
./scripts/logs_cli.py list-runs
./scripts/logs_cli.py show-steps --latest
./scripts/logs_cli.py follow --latest
```

## Container Permission Issues

**Symptom:** Files created inside the container are owned by root or a wrong UID on the host.

The container user `kvothe` is created with the host UID/GID at launch time. If you see
permission mismatches, ensure you are not launching the container as root and that
`SYGALDRY_PROJECT_ID` is set consistently across launches.

## Disk Space

**Symptom:** Docker build fails with no space, or Spack install fails mid-way.

```bash
df -h                    # check disk usage
docker system df         # check Docker disk usage
docker system prune      # remove unused images/containers (careful!)
```

The Spack store (~42 GB) must not be on a disk that fills up during use.
Set `ZEPHYR_CACHE_ROOT` to a larger disk if needed.

## Getting More Help

1. Run `container/diagnose_nvidia.sh` and include the output in your GitHub Issue.
2. Open an issue at https://github.com/phi9t/sygaldry/issues
3. For security issues, use GitHub's private vulnerability reporting (see `SECURITY.md`).
