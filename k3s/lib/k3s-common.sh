#!/bin/bash
# Shared functions for K3s integration scripts.

set -eu -o pipefail

# Source canonical path defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.env
source "${SCRIPT_DIR}/paths.env"
export ZEPHYR_CACHE_ROOT ZEPHYR_SHARED_ROOT ZEPHYR_PROJECTS_ROOT ZEPHYR_BUILD_ROOT SYGALDRY_HOME

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [k3s:${BASH_LINENO[0]}] $*" >&2
}

die() {
    log "FATAL: $*"
    exit 1
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
K3S_NAMESPACE="${K3S_NAMESPACE:-sygaldry}"
readonly K3S_NAMESPACE

# shellcheck disable=SC2034  # used in kentai (sourced file)
readonly CONTAINER_IMAGE_DEFAULT="sygaldry/zephyr:base"

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
check_k3s() {
    if ! command -v kubectl &>/dev/null; then
        die "kubectl not found. Run k3s/bootstrap/install-k3s.sh first."
    fi
    if ! kubectl cluster-info &>/dev/null 2>&1; then
        die "K3s cluster not reachable. Is K3s running?"
    fi
}

check_namespace() {
    if ! kubectl get namespace "${K3S_NAMESPACE}" &>/dev/null 2>&1; then
        die "Namespace '${K3S_NAMESPACE}' not found. Run k3s/bootstrap/setup-nvidia.sh first."
    fi
}

check_nvidia_runtime() {
    if ! kubectl get runtimeclass nvidia &>/dev/null 2>&1; then
        die "RuntimeClass 'nvidia' not found. Run k3s/bootstrap/setup-nvidia.sh first."
    fi
}

# ---------------------------------------------------------------------------
# Host directory setup
# ---------------------------------------------------------------------------
ensure_host_dirs() {
    local project_id="$1"
    local project_root="${ZEPHYR_PROJECTS_ROOT}/${project_id}"

    local dirs=(
        "${project_root}/home"
        "${project_root}/config"
        "${project_root}/local_share"
        "${project_root}/outputs"
        "${project_root}/workspace"
        "${ZEPHYR_SHARED_ROOT}/hf_cache"
        "${ZEPHYR_SHARED_ROOT}/uv_cache"
        "${ZEPHYR_SHARED_ROOT}/bazel_cache"
        "${ZEPHYR_SHARED_ROOT}/torch_cache"
        "${ZEPHYR_SHARED_ROOT}/triton_cache"
        "${ZEPHYR_SHARED_ROOT}/nv_compute_cache"
        "${ZEPHYR_SHARED_ROOT}/jax_cache"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "${dir}"
    done
}

# ---------------------------------------------------------------------------
# Pod helpers
# ---------------------------------------------------------------------------
pod_name() {
    local project_id="$1"
    echo "sygaldry-dev-${project_id}"
}

pod_status() {
    local name="$1"
    kubectl get pod -n "${K3S_NAMESPACE}" "${name}" -o jsonpath='{.status.phase}' 2>/dev/null || echo ""
}

wait_pod_ready() {
    local name="$1"
    local timeout="${2:-120}"
    log "Waiting for pod ${name} to be Ready (timeout=${timeout}s)..."
    if ! kubectl wait --for=condition=Ready pod/"${name}" \
        -n "${K3S_NAMESPACE}" --timeout="${timeout}s" 2>/dev/null; then
        die "Pod ${name} did not become Ready within ${timeout}s"
    fi
}
