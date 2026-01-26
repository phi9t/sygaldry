#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/nvidia_fix_$(date +'%Y%m%d_%H%M%S').log"

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

sudo_cmd() {
  if [[ $EUID -eq 0 ]]; then
    run_cmd "$@"
  else
    run_cmd sudo -n "$@"
  fi
}

require_cmd() {
  if ! cmd_exists "$1"; then
    echo "Missing command: $1"
    exit 1
  fi
}

section "Preflight"
run_cmd date
run_cmd uname -a
if [[ -f /etc/os-release ]]; then
  run_cmd cat /etc/os-release
fi

if [[ $EUID -ne 0 ]]; then
  if ! sudo -n true 2>/dev/null; then
    echo "Root access is required. Re-run with sudo (interactive) or as root."
    exit 1
  fi
fi

if ! cmd_exists apt-get; then
  echo "apt-get not found; this script currently supports Debian/Ubuntu"
  exit 1
fi

section "Install Base Dependencies"
sudo_cmd apt-get update
sudo_cmd apt-get install -y --only-upgrade gnupg dirmngr gpg gpg-agent gpgsm gpgv keyboxd || true
sudo_cmd apt-get install -y ubuntu-drivers-common pciutils curl ca-certificates gnupg lsb-release dkms build-essential "linux-headers-$(uname -r)"
sudo_cmd apt-get -f install -y || true
sudo_cmd apt --fix-broken install -y || true

section "Install NVIDIA Driver"
recommended_driver=""
if cmd_exists ubuntu-drivers; then
  recommended_driver=$(ubuntu-drivers devices | awk '/recommended/ {print $3; exit}' || true)
fi

if [[ -z "${recommended_driver}" ]]; then
  recommended_driver="nvidia-driver-545"
  echo "No recommended driver detected; defaulting to ${recommended_driver}"
else
  echo "Recommended driver detected: ${recommended_driver}"
fi

section "Remove Conflicting Server Drivers (if present)"
server_pkgs=$(dpkg -l | awk '/^ii/ && $2 ~ /nvidia-.*-server/ {print $2}' | xargs || true)
if [[ -n "${server_pkgs}" ]]; then
  echo "Purging server driver packages: ${server_pkgs}"
  sudo_cmd apt-get purge -y ${server_pkgs}
  sudo_cmd apt-get autoremove -y
else
  echo "No server driver packages detected"
fi

section "Remove Incomplete CUDA 12.8 Packages (if present)"
cuda_12_8_pkgs=$(dpkg -l | awk '/^iU/ && $2 ~ /^cuda-.*-12-8/ {print $2}' | xargs || true)
if [[ -n "${cuda_12_8_pkgs}" ]]; then
  echo "Purging incomplete CUDA 12.8 packages: ${cuda_12_8_pkgs}"
  sudo_cmd apt-get purge -y ${cuda_12_8_pkgs}
  sudo_cmd apt-get autoremove -y
else
  echo "No incomplete CUDA 12.8 packages detected"
fi

section "Install NVIDIA Driver"
sudo_cmd apt-get install -y "${recommended_driver}"

driver_major="${recommended_driver#nvidia-driver-}"
if ! cmd_exists nvidia-smi; then
  echo "nvidia-smi still missing; installing nvidia-utils-${driver_major}"
  sudo_cmd apt-get install -y "nvidia-utils-${driver_major}" || true
fi

section "Load NVIDIA Kernel Modules"
for mod in nvidia nvidia_modeset nvidia_uvm nvidia_drm; do
  if ! lsmod | grep -q "^${mod}"; then
    sudo_cmd modprobe "${mod}" || true
  fi
done

section "Install NVIDIA Container Toolkit"
if ! cmd_exists nvidia-ctk; then
  sudo_cmd mkdir -p /usr/share/keyrings
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo_cmd gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo_cmd tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo_cmd apt-get update
  sudo_cmd apt-get install -y nvidia-container-toolkit
else
  echo "nvidia-ctk already installed"
fi

section "Configure Docker NVIDIA Runtime"
if cmd_exists nvidia-ctk; then
  sudo_cmd nvidia-ctk runtime configure --runtime=docker
  if cmd_exists systemctl; then
    sudo_cmd systemctl restart docker || true
  else
    sudo_cmd service docker restart || true
  fi
else
  echo "nvidia-ctk not available; skipping Docker runtime configuration"
fi

section "Post-install Validation"
if cmd_exists nvidia-smi; then
  run_cmd nvidia-smi || true
else
  echo "nvidia-smi not found after install"
fi

if cmd_exists docker; then
  run_cmd docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi || true
fi

section "Summary"
echo "Fix log saved to: ${LOG_FILE}"
if [[ -f /var/run/reboot-required ]]; then
  echo "Reboot required: /var/run/reboot-required present"
fi
