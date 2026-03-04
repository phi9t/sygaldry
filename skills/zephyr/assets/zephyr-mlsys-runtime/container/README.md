# MLSys Container Constraint System

This directory contains the three-layer constraint system that ensures UV-installed
Python packages coexist safely with the Spack-managed scientific computing stack.

## Three-Layer Architecture

### Layer 1: Spack-Owned Package Pins (`spack_owned_packages.conf`)

Lists every pip package name that Spack manages (torch, numpy, jax, etc.).
At build time, `uv-install.sh` reads this file and:

1. Sets `UV_NO_BUILD_ISOLATION_PACKAGE` so UV does not attempt to rebuild
   these packages from source.
2. Generates a **constraints file** that pins each listed package to its
   exact Spack-installed version (e.g., `torch==2.9.0`).  UV's resolver
   then treats these versions as immovable.

This prevents UV from pulling a duplicate PyPI copy of torch or numpy
into the venv.

### Layer 2: NVIDIA Override Blocks (`nvidia_overrides.txt`)

Uses UV's `--override` mechanism with impossible markers
(`sys_platform == 'never'`) to block all `nvidia-*` pip meta-packages.
These CUDA runtime libraries are provided by the Docker base image
(nvidia/cuda) and the Spack environment; pip copies would conflict.

Also contains targeted relaxations for packages whose Spack-provided
versions differ from what pip metadata expects (e.g., `python-dateutil`
dist-info reporting `0.0.0`).

### Layer 3: LLM Serving Overrides (`llm_serving_overrides.txt`)

Optional override file for LLM serving packages (vLLM, sglang,
megatron-core) that declare tight pins on torch, triton, etc.

Uses marker-gated relaxations (`sys_platform == 'linux'`) to widen
allowed version ranges so the resolver accepts the Spack-provided
versions, and impossible markers to block pip torch entirely.

Pass this file via `UV_EXTRA_OVERRIDES` when installing LLM serving
packages.

## In-Container Scripts

- **entrypoint.sh** -- Docker ENTRYPOINT that activates the venv and
  sets up Spack view / CUDA paths before exec'ing the user command.
- **run-job.sh** -- Job runner that optionally captures stdout/stderr
  to a log file under `/repo/.zephyr-mlsys/logs/`.

## How It Fits Together

```
docker build (build-mlsys.sh)
  |
  v
Spack base image (torch, jax, numpy, triton, CUDA)
  |
  v
uv-install.sh  +  spack_owned_packages.conf  (Layer 1: pin Spack pkgs)
                +  nvidia_overrides.txt        (Layer 2: block nvidia-*)
                +  llm_serving_overrides.txt   (Layer 3: relax LLM pins)
  |
  v
Baked image with /opt/repo-venv (UV packages layered on top of Spack)
```
