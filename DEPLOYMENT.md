# Deployment Guide

This guide covers a fresh-machine setup for running Sygaldry on a Linux host.

## Supported Platform

- **OS:** Ubuntu 22.04 or 24.04 (bare metal or PCIe passthrough VM)
- **GPU:** NVIDIA GPU, any generation supported by CUDA 12.9
- **Not supported:** WSL2, macOS, CPU-only environments

## 1) NVIDIA Drivers

Install the NVIDIA driver for your GPU:

```bash
sudo apt update
sudo apt install -y nvidia-driver-550   # or newer; match your GPU
sudo reboot
```

Verify:

```bash
nvidia-smi
```

The output must show your GPU and driver version. If this fails, see
`container/NVIDIA_FIXES.md` and run `container/diagnose_nvidia.sh`.

## 2) Docker + NVIDIA Container Toolkit

Install Docker Engine (not Docker Desktop):

```bash
# Official Docker install script
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER   # allow non-root docker
newgrp docker
```

Install NVIDIA Container Toolkit:

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update && sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Verify:

```bash
docker info | grep -i nvidia
docker run --rm --gpus all nvidia/cuda:12.9.1-base-ubuntu24.04 nvidia-smi
```

## 3) Go 1.23+

Required for the Temporal orchestration engine:

```bash
GO_VERSION=1.23.5
curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | \
  sudo tar -C /usr/local -xzf -
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
source ~/.bashrc
go version
```

## 4) Disk Space Planning

| Component | Typical Size |
|---|---|
| NVIDIA drivers | ~1–2 GB |
| Docker base image (CUDA 12.9 Ubuntu 24.04) | ~5–10 GB |
| Spack store (PyTorch + JAX + CUDA stack) | ~42 GB |
| HuggingFace model cache (varies by model) | 1–100+ GB |
| UV package cache | ~1–5 GB |

Total for a base install: **~60 GB** before any models.

Set a custom cache root if your default disk is small:

```bash
export ZEPHYR_CACHE_ROOT=/path/to/large/disk/zephyr_infra
```

Default is `/mnt/data_infra/zephyr_container_infra`.

## 5) Pull the Snapshot Image

Building the full Spack environment from source takes hours. Pull the prebuilt snapshot instead:

```bash
docker pull ghcr.io/phi9t/sygaldry/zephyr:spack-20260212-082355
```

See `docs/RELEASE_NOTES_2026-02.md` for the current validated snapshot tag and digest.

## 6) Verify the Install

```bash
./container/launch_container.sh --entrypoint verify-gpu.sh
```

This runs PyTorch and JAX GPU checks inside the container. All checks must pass.

For a fast Spack-only verification (no container rebuild):

```bash
./container/launch_container.sh --entrypoint verify-spack.sh
```

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common failure modes.
