# Sygaldry (Zephyr Container Infra)

Sygaldry provides a reproducible container-based dev/build environment for mixed-language, GPU-heavy projects. It combines Docker, Spack, and Bazel, with a Zephyr-focused Spack environment pinned to a known lockfile.

## What’s Included

- Docker-based development container with CUDA 12.9.1 + cuDNN
- Spack-based dependency management (Spack baked into the image)
- Bazel build layer and persistent caches
- A single launcher script with entrypoint dispatch
- Zephyr Spack environment with CUDA-enabled Torch and JAX

## Quick Start

```bash
# Launch the container (auto-builds image if needed)
./container/launch_container.sh

# Inside the container
spack-env-activate
bazel build //...
```

## Container Launcher

The launcher sets up shared host storage, builds the image if needed, and runs the container.

```bash
./container/launch_container.sh
```

By default, it uses:
- Image: `sygaldry/zephyr:base`
- Project root: `/workspace`
- Entry point: `container/entrypoints/default.sh`

### Entrypoint Dispatch

The launcher can dispatch different entrypoint scripts:

```bash
# Default interactive shell
./container/launch_container.sh

# Run a command directly
./container/launch_container.sh bazel build //...
```

Spack install entrypoint lives at:
- `container/entrypoints/spack-install.sh`

## Host Storage Layout

All persistent container state is stored under a shared host root:

```
/mnt/data_infra/zephyr_container_infra/<project_id>/
  monorepo_home/  -> /home/kvothe
  spack_store/    -> /opt/spack_store
  bazel_cache/    -> /opt/bazel_cache
  config/         -> /config
```

## Spack Environments

Primary environment:
- `pkg/zephyr` (CUDA-enabled Torch and JAX)

Legacy environment:
- `pkg/torch_cuda`

Build an environment:

```bash
cd pkg/zephyr
./build.sh
```

Notes:
- If `spack.lock` exists, `build.sh` installs from the lock without reconcretizing.
- `spack_src.yaml` is copied to `spack.yaml` only if needed.

## CUDA Validation

Validation scripts are designed to confirm CUDA-enabled Torch and JAX. Use these once the Zephyr Spack environment is installed.

## Environment Variables

Launcher customization:
- `SYGALDRY_PROJECT_ID` — project isolation namespace
- `SYGALDRY_IMAGE` — override image name (default `sygaldry/zephyr:base`)
- `SYGALDRY_GPU=false` — disable GPU support

Version control:
- `BAZEL_VERSION=6.4.0`
- `PYTHON_VERSION=3.13`
- `RUST_VERSION=1.79.0`

## Key Files

- `container/launch_container.sh` — primary entry point
- `container/dev_container.dockerfile` — base image definition
- `container/entrypoints/` — entrypoint scripts
- `pkg/zephyr/spack_src.yaml` — Zephyr environment specs
- `pkg/zephyr/spack.lock` — pinned dependency graph
- `pkg/zephyr/DEPENDENCY_GRAPH.md` — dependency summary
- `SYSTEM_DESIGN.md` — system design doc
- `container/ZEPHYR_SYSTEM_DESIGN.md` — container design
- `container/ZEPHYR_HACKERS_GUIDE.md` — ops and usage guide

## Troubleshooting

- NVIDIA: see `container/NVIDIA_FIXES.md`
- Container inspection: `container/inspect_nvidia_setup.sh`
- Diagnostics: `container/diagnose_nvidia.sh`

## License

Internal / project-specific. Add licensing details if this is shared externally.
