# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Sygaldry is a Bazel + Spack + Docker mono-repo build system designed for reproducible, hermetic builds across Python, C++, and Rust. The system combines:

- **Docker**: Encapsulates runtime environment (like a chroot jail)
- **Spack**: Manages external dependencies (HPC/system libraries: Boost, MPI, HDF5, etc.)
- **Bazel**: Orchestrates builds for mixed-language projects within the monorepo
- **Launcher Script**: Mounts host directories (XDG data paths) for persistence

## Architecture

```
Host (XDG-compliant paths)
 ├─ ~/.local/share/sygaldry_container/<project_id>/
 │   ├─ monorepo_home/     → /home/kvothe (container home)
 │   ├─ spack_store/       → /opt/spack_store (Spack packages)
 │   ├─ bazel_cache/       → /opt/bazel_cache (build cache)
 │   └─ spack_src/         → /opt/spack_src (Spack source)
 └─ Docker Container
      ├─ Spack-managed deps with view at /opt/spack_store/view
      ├─ Bazel build system with persistent cache
      ├─ Dynamic UID/GID mapping for file permissions
      └─ Python / C++ / Rust toolchains

Logging Pattern:
All shell scripts use log functions with line numbers:
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [script-name:${BASH_LINENO[0]}] $*" >&2
}
```

### Repository Structure

- **`container/`** - Docker container definitions and scripts
  - `dev_container.dockerfile` - Ubuntu 24.04 base with dynamic user creation
  - `launch_container.sh` - XDG-compliant launcher with auto-build and GPU support
  - `setup_user_environment.sh` - User environment setup (Rust, uv, bashrc)
  - `setup_docker_on_host_machine.sh` - Docker installation helper
- **`pkg/`** - Package-specific environments
  - `torch_cuda/` - PyTorch with CUDA support (enhanced build.sh)
- **`tools/`** - Simplified Spack build system
  - `spack_src.yaml` - Single source template for all environments
  - `build.sh` - Enhanced build script with logging

## Development Workflow

### 1. Container Setup

**Launch development container** (auto-builds if needed):
```bash
./container/launch_container.sh
```

This creates a containerized environment with:
- XDG Base Directory compliant persistence
- Dynamic UID/GID mapping for file permissions  
- NVIDIA GPU access (if available)
- Spack package manager with persistent store
- Bazel build system with persistent cache

### 2. Spack Environment Setup

The simplified system uses a single template approach:

**Build main development environment**:
```bash
cd tools
./build.sh
```

**Build PyTorch CUDA environment**:
```bash
cd pkg/torch_cuda  
./build.sh
```

Both scripts:
1. Convert `spack_src.yaml` → `spack.yaml`
2. Concretize the environment
3. Install all packages
4. Generate Spack view for Bazel integration

### 3. Bazel Builds

**Build mixed-language targets**:
```bash
bazel build //cpp:main //rust:main //python:app
```

**Common Bazel commands**:
- `bazel build //...` - Build all targets
- `bazel test //...` - Run all tests
- `bazel clean` - Clean build artifacts
- `bazel query //...` - List all targets

## Key Files

### Spack Configuration
- `spack.yaml` - Spack environment specification with unified concretization
- `spack.lock` - Lockfiles for reproducible builds
- `spack_src.yaml` - Source templates (copied to `spack.yaml` during build)

### Bazel Configuration  
- `WORKSPACE` - Bazel workspace definition with external dependencies
- `BUILD` files - Build target definitions per package
- `third_party/BUILD.spack` - Spack-managed dependency integration
- `.bazelrc` - Bazel configuration and caching settings

### Container Integration
- Spack view available at `/opt/spack_store/view` for Bazel consumption
- Bazel cache persisted to host via `/opt/bazel_cache` mount
- Container uses dynamic UID/GID mapping to match host user
- All persistent data stored in XDG-compliant paths on host

## Environment Requirements

- Docker with NVIDIA runtime support (optional, for GPU workloads)
- XDG Base Directory specification compliance for persistent storage
- Spack source repository automatically cloned to `~/.local/share/sygaldry_container/<project_id>/spack_src`
- Bazel 6.0+ for mixed-language support

## Implementation Notes

- **Simplified Spack System**: Single `spack_src.yaml` template per environment, converted by `build.sh` scripts
- **Enhanced Logging**: All shell scripts include line numbers in log output for debugging
- **XDG Compliance**: Persistent data stored in `~/.local/share/sygaldry_container/<project_id>/`
- **Dynamic User Mapping**: Container matches host UID/GID for seamless file permissions
- **Auto-Build**: Launcher script detects changes and rebuilds container images automatically