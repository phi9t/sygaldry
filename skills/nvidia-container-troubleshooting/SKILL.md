---
name: nvidia-container-troubleshooting
description: Diagnose and fix NVIDIA GPU access issues in Docker/OCI containers (NVML initialization failures, missing /dev/nvidia* nodes, misconfigured NVIDIA container runtime/CTK, cgroup v2 device rules, CDI device injection, or driver/library mismatches). Use when CUDA containers cannot see GPUs, `nvidia-smi` fails inside a container, or `--gpus` does not work.
---

# Nvidia Container Troubleshooting

## Overview

Use this skill to quickly isolate host vs container runtime problems and apply the smallest fix that restores GPU visibility in containers.

## Workflow

1. **Confirm host driver health**
   - Run `nvidia-smi` on the host. If this fails, fix host driver first.
   - Run `nvidia-container-cli info` to verify driver/library discovery.

2. **Check Docker GPU runtime wiring**
   - `docker info --format '{{json .Runtimes}}'`
   - Ensure `nvidia-container-runtime` is installed and discoverable.
   - If missing or stale, run `nvidia-ctk runtime configure --runtime=docker` and restart Docker.

3. **Validate device node injection**
   - `docker run --rm --gpus all --entrypoint=ls <image> -l /dev/nvidia*`
   - Missing `/dev/nvidiactl` or `/dev/nvidia-uvm` generally indicates runtime injection failed.

4. **Cgroup v2 + NVML init failures**
   - If `nvidia-smi` fails inside container with `Failed to initialize NVML: Unknown Error`, check:
     - `/etc/nvidia-container-runtime/config.toml` → `no-cgroups` should be `false` on cgroup v2 hosts.
     - Restart Docker after edits.
   - Temporary isolation: `--privileged` should make NVML succeed if cgroup device rules are the root cause.

5. **CDI sanity check (optional but robust)**
   - Confirm CDI spec exists: `/var/run/cdi/nvidia.yaml`.
   - Validate with CDI injection: `docker run --rm --device nvidia.com/gpu=all <image> nvidia-smi`.

6. **Verify GPU workload**
   - Re-run the original container command with `--gpus all` (no `-it` in non-TTY environments).

## NVML Failures Reference

For a detailed NVML initialization breakdown and root-cause mapping, read `references/nvml-init.md`.

## Commands (copy/paste)

```bash
# Host
nvidia-smi
nvidia-container-cli info

# Runtime
docker info --format '{{json .Runtimes}}'
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Container checks
docker run --rm --gpus all <image> nvidia-smi
docker run --rm --gpus all --entrypoint=ls <image> -l /dev/nvidia*

docker run --rm --device nvidia.com/gpu=all <image> nvidia-smi
```
