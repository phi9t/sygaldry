#!/bin/bash
# Import a Docker image into K3s containerd so pods can use it without a registry.
#
# Prefers nerdctl (direct load into K3s containerd, no pipe overhead) and falls
# back to `docker save | k3s ctr images import` when nerdctl is unavailable.
#
# Usage:
#   sudo k3s/bootstrap/import-image.sh <image>
#   sudo k3s/bootstrap/import-image.sh sygaldry/zephyr:spack-20260212-082355

set -eu -o pipefail

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [import-image:${BASH_LINENO[0]}] $*" >&2
}

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (or via sudo)." >&2
    exit 1
fi

IMAGE="${1:-}"
if [[ -z "${IMAGE}" ]]; then
    echo "Usage: $0 <docker-image>" >&2
    exit 2
fi

# ------------------------------------------------------------------
# Check if already imported
# ------------------------------------------------------------------
if k3s crictl images 2>/dev/null | grep -q "${IMAGE}"; then
    log "Image ${IMAGE} already present in K3s containerd."
    exit 0
fi

# ------------------------------------------------------------------
# Verify image exists in Docker
# ------------------------------------------------------------------
if ! docker image inspect "${IMAGE}" &>/dev/null; then
    log "Image ${IMAGE} not found in Docker. Pull or build it first."
    exit 1
fi

# ------------------------------------------------------------------
# Import: prefer nerdctl → K3s containerd socket, fallback to docker save pipe
# ------------------------------------------------------------------
K3S_CONTAINERD_SOCK="/run/k3s/containerd/containerd.sock"

if command -v nerdctl &>/dev/null && [[ -S "${K3S_CONTAINERD_SOCK}" ]]; then
    log "Using nerdctl to load ${IMAGE} directly into K3s containerd..."
    docker save "${IMAGE}" | nerdctl \
        --address "${K3S_CONTAINERD_SOCK}" \
        --namespace k8s.io \
        load
else
    log "Exporting ${IMAGE} from Docker and importing into K3s containerd..."
    log "This may take a while for large images."
    docker save "${IMAGE}" | k3s ctr images import -
fi

log "Import complete."

# ------------------------------------------------------------------
# Persist for K3s restarts (auto-import directory)
# ------------------------------------------------------------------
IMAGES_DIR="/var/lib/rancher/k3s/agent/images"
mkdir -p "${IMAGES_DIR}"
TAR_NAME="$(echo "${IMAGE}" | tr '/:' '_').tar"
if [[ ! -f "${IMAGES_DIR}/${TAR_NAME}" ]]; then
    log "Saving ${IMAGE} to ${IMAGES_DIR}/${TAR_NAME} for K3s restart persistence..."
    docker save "${IMAGE}" -o "${IMAGES_DIR}/${TAR_NAME}"
fi

# ------------------------------------------------------------------
# Verify
# ------------------------------------------------------------------
if k3s crictl images 2>/dev/null | grep -q "${IMAGE}"; then
    log "Verified: ${IMAGE} is available in K3s containerd."
else
    log "WARNING: Image may not have imported correctly. Check with: sudo k3s crictl images"
fi
