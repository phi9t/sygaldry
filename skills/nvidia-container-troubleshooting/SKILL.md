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

---

## NVML Deep Dive

### What NVML init actually does

`nvidia-smi` calls `nvmlInit()` from `libnvidia-ml.so`. That initialization sequence typically:

- Loads the NVML shared library (in containers this is injected by the NVIDIA runtime).
- Opens control devices such as `/dev/nvidiactl` and per-GPU nodes like `/dev/nvidia0`.
- Issues IOCTLs to query driver version, enumerate GPUs, and fetch device state.
- Optionally touches `/dev/nvidia-uvm` and `/dev/nvidia-modeset` depending on driver features.

If any of the early control-device opens or IOCTLs fail, NVML often returns `NVML_ERROR_UNKNOWN`,
which `nvidia-smi` surfaces as `Failed to initialize NVML: Unknown Error`.

### Why it fails in containers even when /dev/nvidia* exists

The NVIDIA container runtime does two critical things:

1. **Device node injection**: bind-mounts `/dev/nvidia*` into the container.
2. **Device cgroup rules**: adds cgroup device allow rules so container processes can open and issue IOCTLs against those devices.

On cgroup v2 hosts (systemd + unified cgroup hierarchy), device access is enforced by cgroups.
If the runtime is configured with `no-cgroups = true`, it *skips* configuring device rules.
The nodes may still appear in `/dev`, but access to them is denied by cgroup policy.
The result is NVML failing during initialization, typically with `Unknown Error`.

This failure mode often presents as:

- `nvidia-smi` works on the host
- `nvidia-container-cli info` works on the host
- `docker run --rm --gpus all <image> nvidia-smi` fails with `Failed to initialize NVML: Unknown Error`
- `docker run --rm --privileged --gpus all <image> nvidia-smi` succeeds (privileged bypasses device cgroup restrictions)

That combination strongly implicates device cgroup rules rather than drivers or libraries.

### Quick diagnosis checklist

- Confirm host driver works: `nvidia-smi`
- Confirm runtime sees GPUs: `nvidia-container-cli info`
- Confirm cgroup version: `docker info | grep -i 'Cgroup Version'`
- Confirm runtime config: `/etc/nvidia-container-runtime/config.toml`
  - If `no-cgroups = true` on cgroup v2, NVML init failures are expected

### Fix: enable cgroup management

Set `no-cgroups = false` in `/etc/nvidia-container-runtime/config.toml`, then restart Docker:

```bash
sudo sed -i 's/^no-cgroups = true/no-cgroups = false/' /etc/nvidia-container-runtime/config.toml
sudo systemctl restart docker
```

If the runtime config is stale or incomplete, reconfigure via CTK:

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

After this change, `--gpus all` should correctly set device cgroup rules and NVML will initialize.

### CDI cross-check

If you suspect the legacy `--gpus` path is misconfigured, validate the CDI path:

```bash
docker run --rm --device nvidia.com/gpu=all <image> nvidia-smi
```

If CDI works and `--gpus all` does not, your NVIDIA container runtime integration with Docker
is still misconfigured. Re-run CTK and re-check `/etc/docker/daemon.json`.
