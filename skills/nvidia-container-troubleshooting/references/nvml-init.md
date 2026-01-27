# NVML initialization failures in containers

## What NVML init actually does

`nvidia-smi` calls `nvmlInit()` from `libnvidia-ml.so`. That initialization sequence typically:

- Loads the NVML shared library (in containers this is injected by the NVIDIA runtime).
- Opens control devices such as `/dev/nvidiactl` and per-GPU nodes like `/dev/nvidia0`.
- Issues IOCTLs to query driver version, enumerate GPUs, and fetch device state.
- Optionally touches `/dev/nvidia-uvm` and `/dev/nvidia-modeset` depending on driver features.

If any of the early control-device opens or IOCTLs fail, NVML often returns `NVML_ERROR_UNKNOWN`, which `nvidia-smi` surfaces as `Failed to initialize NVML: Unknown Error`.

## Why it fails in containers even when /dev/nvidia* exists

The NVIDIA container runtime does two critical things:

1. **Device node injection**: bind-mounts `/dev/nvidia*` into the container.
2. **Device cgroup rules**: adds cgroup device allow rules so container processes can open and issue IOCTLs against those devices.

On cgroup v2 hosts (systemd + unified cgroup hierarchy), device access is enforced by cgroups. If the runtime is configured with `no-cgroups = true`, it *skips* configuring device rules. The nodes may still appear in `/dev`, but access to them is denied by cgroup policy. The result is NVML failing during initialization, typically with `Unknown Error`.

This failure mode often presents as:

- `nvidia-smi` works on the host
- `nvidia-container-cli info` works on the host
- `docker run --rm --gpus all <image> nvidia-smi` fails with `Failed to initialize NVML: Unknown Error`
- `docker run --rm --privileged --gpus all <image> nvidia-smi` succeeds (privileged bypasses device cgroup restrictions)

That combination strongly implicates device cgroup rules rather than drivers or libraries.

## Quick diagnosis checklist

- Confirm host driver works: `nvidia-smi`
- Confirm runtime sees GPUs: `nvidia-container-cli info`
- Confirm cgroup version: `docker info | rg -i 'Cgroup Version'`
- Confirm runtime config: `/etc/nvidia-container-runtime/config.toml`
  - If `no-cgroups = true` on cgroup v2, NVML init failures are expected

## Fix: enable cgroup management

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

## CDI cross-check (optional)

If you suspect the legacy `--gpus` path is misconfigured, validate the CDI path:

```bash
docker run --rm --device nvidia.com/gpu=all <image> nvidia-smi
```

If CDI works and `--gpus all` does not, your NVIDIA container runtime integration with Docker is still misconfigured. Re-run CTK and re-check `/etc/docker/daemon.json`.
