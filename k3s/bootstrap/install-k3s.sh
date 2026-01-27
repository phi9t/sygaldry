#!/bin/bash
# Install K3s single-node server.
#
# Usage:
#   sudo k3s/bootstrap/install-k3s.sh
#
# K3s is installed with Traefik and ServiceLB disabled (not needed for
# single-node GPU dev infrastructure). The kubeconfig is made world-readable
# so non-root users can use kubectl.

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [install-k3s:${BASH_LINENO[0]}] $*" >&2
}

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (or via sudo)." >&2
    exit 1
fi

# ------------------------------------------------------------------
# Install K3s
# ------------------------------------------------------------------
if command -v k3s &>/dev/null; then
    log "K3s already installed: $(k3s --version)"
else
    log "Installing K3s..."
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_EXEC="server --disable=traefik --disable=servicelb --write-kubeconfig-mode=644" sh -
    log "K3s installed: $(k3s --version)"
fi

# ------------------------------------------------------------------
# Copy kubeconfig for non-root kubectl
# ------------------------------------------------------------------
KUBECONFIG_SRC="/etc/rancher/k3s/k3s.yaml"
if [[ -f "${KUBECONFIG_SRC}" ]]; then
    REAL_USER="${SUDO_USER:-${USER}}"
    REAL_HOME=$(eval echo "~${REAL_USER}")
    KUBE_DIR="${REAL_HOME}/.kube"
    mkdir -p "${KUBE_DIR}"
    cp "${KUBECONFIG_SRC}" "${KUBE_DIR}/config"
    chown -R "$(id -u "${REAL_USER}"):$(id -g "${REAL_USER}")" "${KUBE_DIR}"
    chmod 600 "${KUBE_DIR}/config"
    log "Kubeconfig copied to ${KUBE_DIR}/config"
fi

# ------------------------------------------------------------------
# Verify
# ------------------------------------------------------------------
log "Waiting for node to be Ready..."
kubectl wait --for=condition=Ready node --all --timeout=60s
kubectl get nodes
log "K3s install complete."
