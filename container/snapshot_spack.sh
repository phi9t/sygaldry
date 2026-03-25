#!/bin/bash
#
# Spack Snapshot Image Builder
# =============================
#
# Builds a self-contained Docker image with the Spack store baked in.
# The resulting image needs no host-mounted Spack store -- it contains
# PyTorch, JAX, and all other Zephyr packages out of the box.
#
# USAGE:
#   ./container/snapshot_spack.sh                     # build + verify
#   ./container/snapshot_spack.sh --tag my-tag        # custom tag
#   ./container/snapshot_spack.sh --no-verify         # skip post-build verification
#   ./container/snapshot_spack.sh --push              # build + verify + push to GHCR
#   ./container/snapshot_spack.sh --dry-run           # show commands only
#
# PREREQUISITES:
#   - Docker with BuildKit support
#   - sygaldry/zephyr:base image must exist
#   - Spack store must be built (install_tree populated)
#   - pkg/zephyr/spack.lock must exist
#   - For --push: docker login to target registry
#
# ENVIRONMENT VARIABLES:
#   SYGALDRY_SPACK_STORE  - Host path to spack store
#                           (default: /mnt/data_infra/zephyr_container_infra/sygaldry/spack_store)
#   SYGALDRY_IMAGE_BASE   - Base image name (default: sygaldry/zephyr:base)
#   SYGALDRY_IMAGE_SPACK  - Snapshot image name (default: sygaldry/zephyr:spack)
#   GITHUB_TOKEN          - GitHub token for GHCR auth (optional; used if not already logged in)
#

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/snapshot_common.sh"

# ============================================================================
# Configuration
# ============================================================================

readonly DEFAULT_SPACK_STORE="/mnt/data_infra/zephyr_container_infra/sygaldry/spack_store"
readonly HOST_SPACK_STORE="${SYGALDRY_SPACK_STORE:-${DEFAULT_SPACK_STORE}}"

readonly BASE_IMAGE="${SYGALDRY_IMAGE_BASE:-sygaldry/zephyr:base}"
SNAPSHOT_TAG="${SYGALDRY_IMAGE_SPACK:-sygaldry/zephyr:spack}"

DRY_RUN=false
VERIFY=true
PUSH=false
readonly REGISTRY="ghcr.io/phi9t/sygaldry"

# ============================================================================
# Helpers
# ============================================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [snapshot:${BASH_LINENO[0]}] $*" >&2
}

error() {
    log "ERROR: $*"
    exit 1
}

# ============================================================================
# Argument parsing
# ============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            SNAPSHOT_TAG="${2:-}"
            [[ -z "${SNAPSHOT_TAG}" ]] && error "Missing value for --tag"
            shift 2
            ;;
        --tag=*)
            SNAPSHOT_TAG="${1#*=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verify)
            VERIFY=true
            shift
            ;;
        --no-verify)
            VERIFY=false
            shift
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--tag IMAGE:TAG] [--dry-run] [--no-verify] [--push]"
            echo ""
            echo "Build a self-contained Sygaldry image with the Spack store baked in."
            echo ""
            echo "Options:"
            echo "  --tag TAG          Docker image tag (default: sygaldry/zephyr:spack)"
            echo "  --dry-run          Show the docker build command without executing"
            echo "  --verify           Run post-build verification (default: on)"
            echo "  --no-verify        Skip post-build verification"
            echo "  --push             Push to GHCR after build+verify"
            echo ""
            echo "Environment variables:"
            echo "  SYGALDRY_SPACK_STORE   Host path to spack store"
            echo "  SYGALDRY_IMAGE_BASE    Base image (default: sygaldry/zephyr:base)"
            echo "  SYGALDRY_IMAGE_SPACK   Snapshot image tag (default: sygaldry/zephyr:spack)"
            echo "  GITHUB_TOKEN           GitHub token for GHCR auth (optional)"
            exit 0
            ;;
        --registry|--registry=*)
            error "--registry is no longer supported; publish is GHCR-only (${REGISTRY})"
            ;;
        *)
            error "Unknown argument: $1"
            ;;
    esac
done

readonly SNAPSHOT_TAG
readonly DRY_RUN
readonly VERIFY
readonly PUSH

# ============================================================================
# Validation
# ============================================================================

log "Validating prerequisites..."

# Base image
if ! docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1; then
    error "Base image '${BASE_IMAGE}' not found. Build it first with 'zephyr build'."
fi
log "  Base image: ${BASE_IMAGE} (found)"

# Spack store
if [[ ! -d "${HOST_SPACK_STORE}/install_tree" ]]; then
    error "Spack install_tree not found at ${HOST_SPACK_STORE}/install_tree"
fi
if [[ ! -d "${HOST_SPACK_STORE}/._view" ]]; then
    error "Spack view not found at ${HOST_SPACK_STORE}/._view"
fi
log "  Spack store: ${HOST_SPACK_STORE} (found)"

# Env metadata
if [[ ! -f "${PROJECT_ROOT}/pkg/zephyr/spack.lock" ]]; then
    error "spack.lock not found at ${PROJECT_ROOT}/pkg/zephyr/spack.lock (run spack concretize first)"
fi
if [[ ! -f "${PROJECT_ROOT}/pkg/zephyr/spack.yaml" ]]; then
    # Auto-create from template
    if [[ -f "${PROJECT_ROOT}/pkg/zephyr/spack_src.yaml" ]]; then
        log "  Creating spack.yaml from spack_src.yaml..."
        cp "${PROJECT_ROOT}/pkg/zephyr/spack_src.yaml" "${PROJECT_ROOT}/pkg/zephyr/spack.yaml"
    else
        error "Neither spack.yaml nor spack_src.yaml found in pkg/zephyr/"
    fi
fi
log "  Env metadata: pkg/zephyr/spack.{yaml,lock} (found)"

# Entrypoints
if [[ ! -d "${PROJECT_ROOT}/container/entrypoints" ]]; then
    error "Entrypoints directory not found at ${PROJECT_ROOT}/container/entrypoints"
fi
log "  Entrypoints: container/entrypoints/ (found)"

# BuildKit
if ! docker buildx version >/dev/null 2>&1; then
    log "  WARNING: docker buildx not found; falling back to DOCKER_BUILDKIT=1"
fi

# ============================================================================
# Size report
# ============================================================================

log ""
log "Snapshot contents (approximate sizes):"
install_tree_size="$(du -sh "${HOST_SPACK_STORE}/install_tree" 2>/dev/null | cut -f1)"
view_size="$(du -sh "${HOST_SPACK_STORE}/._view" 2>/dev/null | cut -f1)"
misc_size="$(du -sh "${HOST_SPACK_STORE}/misc_cache" 2>/dev/null | cut -f1)"
log "  install_tree:  ${install_tree_size}"
log "  ._view:        ${view_size}"
log "  misc_cache:    ${misc_size}"
log "  (build_stage and source_cache excluded)"
log ""

# ============================================================================
# Build
# ============================================================================

build_cmd=(
    docker build
    --file "${SCRIPT_DIR}/spack_snapshot.dockerfile"
    --build-context "spack_store=${HOST_SPACK_STORE}"
    --tag "${SNAPSHOT_TAG}"
    "${PROJECT_ROOT}"
)

log "Build command:"
log "  DOCKER_BUILDKIT=1 ${build_cmd[*]}"
log ""

if [[ "${DRY_RUN}" == "true" ]]; then
    log "Dry run -- not executing."
    exit 0
fi

log "Building snapshot image: ${SNAPSHOT_TAG}"
log "This may take 10-20 minutes to copy ~22 GB into the image layer..."
log ""

export DOCKER_BUILDKIT=1
if ! "${build_cmd[@]}"; then
    error "Docker build failed"
fi

log ""
log "=============================================="
log "Snapshot image built successfully!"
log "=============================================="
log ""

# Report final size
image_size="$(docker image inspect "${SNAPSHOT_TAG}" --format='{{.Size}}' 2>/dev/null || echo "unknown")"
if [[ "${image_size}" != "unknown" ]]; then
    image_size_gb="$(echo "scale=1; ${image_size} / 1073741824" | bc 2>/dev/null || echo "${image_size}")"
    log "Image size: ${image_size_gb} GB"
fi
log ""

# Verify label
baked_label="$(docker inspect --format='{{index .Config.Labels "sygaldry.spack.baked"}}' "${SNAPSHOT_TAG}" 2>/dev/null || echo "")"
if [[ "${baked_label}" == "true" ]]; then
    log "Label sygaldry.spack.baked=true verified"
else
    log "WARNING: sygaldry.spack.baked label not found on image"
fi

# ============================================================================
# Post-build verification
# ============================================================================

if [[ "${VERIFY}" == "true" ]]; then
    log ""
    log "Running post-build verification..."
    log ""
    if ! bash "${SCRIPT_DIR}/verify_snapshot.sh" "${SNAPSHOT_TAG}"; then
        error "Post-build verification failed! Image may be broken."
    fi
    log ""
    log "Post-build verification passed."
else
    log "Verification skipped (--no-verify)."
fi

# ============================================================================
# Push to registry
# ============================================================================

if [[ "${PUSH}" == "true" ]]; then
    log ""
    log "=============================================="
    log "Pushing to registry"
    log "=============================================="
    log ""

    REGISTRY_HOST="ghcr.io"
    if ! docker login "${REGISTRY_HOST}" --get-login >/dev/null 2>&1; then
        if [[ -n "${GITHUB_TOKEN:-}" ]]; then
            log "Authenticating to ghcr.io with GITHUB_TOKEN..."
            echo "${GITHUB_TOKEN}" | docker login ghcr.io -u "$(echo "${REGISTRY}" | cut -d/ -f2)" --password-stdin
        else
            error "Not authenticated to ${REGISTRY_HOST}. Run: docker login ${REGISTRY_HOST}"
        fi
    fi
    log "Registry auth: OK"

    DATE_TAG="$(date +%Y%m%d)"
    snapshot_tag_and_push "${SNAPSHOT_TAG}" "${REGISTRY}/zephyr" "spack" "${DATE_TAG}" 3 \
        || error "Push failed"

    log ""
    log "Push complete!"
    log "  ${REGISTRY}/zephyr:spack"
    log "  ${REGISTRY}/zephyr:spack-${DATE_TAG}"
    log ""
    log "Pull with:"
    log "  docker pull ${REGISTRY}/zephyr:spack"
fi

# ============================================================================
# Usage hints
# ============================================================================

log ""
log "Usage:"
log ""
log "  # Standalone (no launcher, no host mounts for Spack):"
log "  docker run --rm -it --gpus all ${SNAPSHOT_TAG}"
log ""
log "  # Via launcher:"
log "  SYGALDRY_IMAGE=${SNAPSHOT_TAG} zephyr shell"
log ""
log "  # Multi-repo:"
log "  SYGALDRY_IMAGE=${SNAPSHOT_TAG} zephyr --repo /path/to/project shell"
log ""
log "  # Verify GPU:"
log "  SYGALDRY_IMAGE=${SNAPSHOT_TAG} zephyr --entrypoint verify-spack shell"
log ""
if [[ "${PUSH}" == "true" ]]; then
    log "  # Pull from registry:"
    log "  docker pull ${REGISTRY}/zephyr:spack"
    log ""
fi
