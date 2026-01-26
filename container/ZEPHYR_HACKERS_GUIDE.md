# Zephyr Container Infra: Hacker's Guide

This is the practical, operator-focused guide for running, debugging, and extending the Zephyr container environment.

---

## Quick Start

```
./container/launch_container.sh
```

Run a command directly:

```
./container/launch_container.sh -- bash -lc "echo hello"
```

Pick a specific entrypoint:

```
./container/launch_container.sh --entrypoint=spack-install -- --help
```

---

## Long Build Logging (Recommended)

```
LOG=/mnt/data_infra/zephyr_container_infra/build_logs/zephyr-build-$(date +%Y%m%d-%H%M%S).log
mkdir -p "$(dirname "$LOG")"
./container/launch_container.sh -- bash -lc "cd /workspace/pkg/zephyr && ./build.sh" 2>&1 | tee "$LOG"
```

Monitor:

```
tail -f "$LOG"
```

---

## Validate Torch + JAX CUDA

Once build completes:

```
./container/launch_container.sh -- bash -lc "cd /workspace/pkg/zephyr && spack env activate . && python - <<'PY'
import torch
print('torch_cuda_available', torch.cuda.is_available())
if torch.cuda.is_available():
    x = torch.randn(1024, 1024, device='cuda')
    y = torch.mm(x, x)
    print('torch_matmul_mean', y.mean().item())
import jax
import jax.numpy as jnp
print('jax_devices', jax.devices())
print('jax_dot_mean', jnp.dot(jnp.ones((1024, 1024)), jnp.ones((1024, 1024))).mean())
PY"
```

---

## Entry Points

- `container/entrypoints/default.sh`
  - Runs your command if provided, otherwise opens interactive shell.

- `container/entrypoints/spack-install.sh`
  - Runs `spack install` with your args, then opens shell.

To add a new entrypoint, drop a new script into `container/entrypoints/` and call:

```
./container/launch_container.sh --entrypoint=<name>
```

---

## Where Things Live

Host (shared):
- `/mnt/data_infra/zephyr_container_infra/<project_id>/monorepo_home`
- `/mnt/data_infra/zephyr_container_infra/<project_id>/spack_store`
- `/mnt/data_infra/zephyr_container_infra/<project_id>/bazel_cache`

Container:
- `/opt/spack_src` (Spack v1.1.0)
- `/opt/spack_store` (Spack installs + view)
- `/opt/bazel_cache` (Bazel + CUDA cache)
- `/workspace` (repo)

---

## Common Operations

Enter container shell:
```
./container/launch_container.sh
```

Build Zephyr Spack env:
```
./container/launch_container.sh -- bash -lc "cd /workspace/pkg/zephyr && ./build.sh"
```

Show Spack env:
```
./container/launch_container.sh -- bash -lc "cd /workspace/pkg/zephyr && spack env activate . && spack find"
```

---

## Troubleshooting

### GPU fails to initialize
- Check host driver:
  - `nvidia-smi`
- Ensure CUDA compatibility (host must support CUDA >= 12.9)

### Spack variant errors
- Adjust variants in `pkg/zephyr/spack_src.yaml`
- Re-run `./build.sh` after edits

### Very long builds
- Use build log + `tail -f`
- Keep `spack_store` on shared host storage

---

## Modifying the Environment

- Edit `pkg/zephyr/spack_src.yaml`
- Re-run build:

```
./container/launch_container.sh -- bash -lc "cd /workspace/pkg/zephyr && ./build.sh"
```

---

## Image + Version Notes

- Image: `sygaldry/zephyr:base`
- CUDA: 12.9.1
- Spack: v1.1.0

