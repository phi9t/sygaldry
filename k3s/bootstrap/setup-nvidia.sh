#!/bin/bash
# Configure K3s containerd for NVIDIA GPU runtime, deploy the device plugin,
# and apply the sygaldry namespace + RuntimeClass.
#
# Prerequisites:
#   - K3s installed (install-k3s.sh)
#   - NVIDIA driver + nvidia-container-toolkit installed on the host
#
# Usage:
#   sudo k3s/bootstrap/setup-nvidia.sh

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly K3S_ROOT="${SCRIPT_DIR}/.."

# shellcheck source=../lib/paths.env
source "${SCRIPT_DIR}/../lib/paths.env"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [setup-nvidia:${BASH_LINENO[0]}] $*" >&2
}

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (or via sudo)." >&2
    exit 1
fi

# ------------------------------------------------------------------
# 1. Containerd config template with nvidia runtime
# ------------------------------------------------------------------
CONTAINERD_TMPL_DIR="/var/lib/rancher/k3s/agent/etc/containerd"
mkdir -p "${CONTAINERD_TMPL_DIR}"

TMPL_FILE="${CONTAINERD_TMPL_DIR}/config.toml.tmpl"
if [[ -f "${TMPL_FILE}" ]] && grep -q 'nvidia-container-runtime' "${TMPL_FILE}"; then
    log "containerd config template already has nvidia runtime."
else
    log "Writing containerd config template with nvidia runtime..."
    cat > "${TMPL_FILE}" <<'TOML'
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
  privileged_without_host_devices = false
  runtime_engine = ""
  runtime_root = ""
  runtime_type = "io.containerd.runc.v2"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
  BinaryName = "nvidia-container-runtime"
TOML
fi

# ------------------------------------------------------------------
# 2. Restart K3s to pick up containerd config
# ------------------------------------------------------------------
log "Restarting K3s to apply containerd config..."
systemctl restart k3s
sleep 5

log "Waiting for node to be Ready after restart..."
kubectl wait --for=condition=Ready node --all --timeout=120s

# ------------------------------------------------------------------
# 3. Apply namespace and RuntimeClass
# ------------------------------------------------------------------
log "Applying namespace and RuntimeClass manifests..."
kubectl apply -f "${K3S_ROOT}/manifests/namespace.yaml"
kubectl apply -f "${K3S_ROOT}/manifests/nvidia-runtime-class.yaml"

# ------------------------------------------------------------------
# 4. Deploy NVIDIA device plugin
# ------------------------------------------------------------------
DEVICE_PLUGIN_URL="https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml"
DEVICE_PLUGIN_SHA256="PLACEHOLDER_SHA256_REPLACE_WITH_ACTUAL"

log "Deploying NVIDIA k8s-device-plugin v0.17.0..."
tmp_manifest="$(mktemp)"
trap 'rm -f "${tmp_manifest}"' EXIT
curl -fsSL "${DEVICE_PLUGIN_URL}" -o "${tmp_manifest}"
if [[ "${DEVICE_PLUGIN_SHA256}" != "PLACEHOLDER_SHA256_REPLACE_WITH_ACTUAL" ]]; then
    echo "${DEVICE_PLUGIN_SHA256}  ${tmp_manifest}" | sha256sum -c - || {
        echo "ERROR: device plugin manifest SHA256 mismatch" >&2; exit 1
    }
fi
kubectl apply -f "${tmp_manifest}"

# ------------------------------------------------------------------
# 5. Apply environment ConfigMap
# ------------------------------------------------------------------
log "Applying sygaldry-env ConfigMap..."
kubectl apply -f "${K3S_ROOT}/manifests/configmap-env.yaml"

# ------------------------------------------------------------------
# 6. Wait for device plugin pods and verify GPU allocatable
# ------------------------------------------------------------------
log "Waiting for NVIDIA device plugin pods..."
kubectl -n kube-system rollout status daemonset/nvidia-device-plugin-daemonset --timeout=120s || true

log "Waiting for GPU to appear in node allocatable resources..."
for _ in $(seq 1 30); do
    gpu_count=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "")
    if [[ -n "${gpu_count}" && "${gpu_count}" != "0" ]]; then
        log "GPU allocatable: ${gpu_count}"
        break
    fi
    sleep 5
done

if [[ -z "${gpu_count:-}" || "${gpu_count}" == "0" ]]; then
    log "WARNING: nvidia.com/gpu not yet allocatable. Device plugin may need more time."
    log "Check: kubectl describe node | grep nvidia"
else
    log "NVIDIA setup complete. ${gpu_count} GPU(s) available to K3s."
fi
