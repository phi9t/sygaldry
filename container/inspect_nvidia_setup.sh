#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/nvidia_inspect_$(date +'%Y%m%d_%H%M%S').log"

exec > >(tee -a "${LOG_FILE}") 2>&1

section() {
  echo ""
  echo "============================================================"
  echo "$*"
  echo "============================================================"
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_cmd() {
  echo "+ $*"
  "$@"
}

section "NVIDIA Setup Inspection"
run_cmd date
run_cmd hostname

section "OS / Kernel"
run_cmd uname -a
if [[ -f /etc/os-release ]]; then
  run_cmd cat /etc/os-release
fi

section "Hardware Detection"
if cmd_exists lspci; then
  run_cmd lspci | grep -i nvidia || true
else
  echo "lspci not found"
fi

section "NVIDIA Kernel Modules"
run_cmd lsmod | grep -E '^(nvidia|nouveau)' || true

section "Device Nodes"
run_cmd ls -la /dev/nvidia* || true
run_cmd ls -la /dev/nvidia-caps || true

section "Driver / NVML"
if cmd_exists nvidia-smi; then
  run_cmd nvidia-smi
  run_cmd nvidia-smi -L || true
else
  echo "nvidia-smi not found"
fi

if cmd_exists ldconfig; then
  run_cmd ldconfig -p | grep -E 'libnvidia-ml.so.1|libcuda.so.1' || true
fi

section "Installed Packages"
if cmd_exists dpkg; then
  run_cmd dpkg -l | grep -E 'nvidia-(driver|dkms|utils|kernel|container|cuda)' || true
fi

if cmd_exists dkms; then
  run_cmd dkms status | grep -i nvidia || true
fi

section "Recommended Driver"
if cmd_exists ubuntu-drivers; then
  run_cmd ubuntu-drivers devices || true
else
  echo "ubuntu-drivers not found"
fi

section "Docker / NVIDIA Container Toolkit"
if cmd_exists docker; then
  run_cmd docker --version
  run_cmd docker info || true
else
  echo "docker not found"
fi

if cmd_exists nvidia-ctk; then
  run_cmd nvidia-ctk --version
else
  echo "nvidia-ctk not found"
fi

if [[ -f /etc/docker/daemon.json ]]; then
  run_cmd cat /etc/docker/daemon.json
else
  echo "/etc/docker/daemon.json not found"
fi

section "Summary"
echo "Inspection log saved to: ${LOG_FILE}"
