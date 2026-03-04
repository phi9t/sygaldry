#!/bin/bash
# Build a hermetic MLSys Docker image from config.yaml.
# The generated image has a Python venv baked in on top of the Spack base image.
#
# Usage: build-mlsys.sh [--config <path>] [--force-rebuild] [--no-cache]
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
KIT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly KIT_ROOT
REPO_ROOT="$(cd "${KIT_ROOT}/.." && pwd)"
readonly REPO_ROOT

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [build-mlsys:${BASH_LINENO[0]}] $*" >&2
}

err() {
    log "ERROR: $*"
    exit 1
}

usage() {
    cat <<'USAGE'
Usage:
  build-mlsys.sh [--config <path>] [--force-rebuild] [--no-cache]

Options:
  --config <path>    Path to config.yaml (default: <kit>/config.yaml)
  --force-rebuild    Rebuild even if image.lock exists and is current
  --no-cache         Pass --no-cache to docker buildx build

Reads config.yaml, builds a hermetic MLSys Docker image with Python venv baked
in, and writes image.lock with the built image digest.

Run this once (or when dependencies change) before launch-mlsys.sh.
USAGE
}

CONFIG_FILE="${KIT_ROOT}/config.yaml"
NO_CACHE=0
FORCE_REBUILD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_FILE="${2:?--config requires a value}"
            shift 2
            ;;
        --force-rebuild)
            FORCE_REBUILD=1
            shift
            ;;
        --no-cache)
            NO_CACHE=1
            shift
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            err "Unknown argument: $1"
            ;;
    esac
done

[[ -f "${CONFIG_FILE}" ]] || err "config.yaml not found: ${CONFIG_FILE}"
command -v docker >/dev/null 2>&1 || err "docker not found in PATH"
command -v python3 >/dev/null 2>&1 || err "python3 not found in PATH"

# ---------------------------------------------------------------------------
# Prepare build context via Python helper
# ---------------------------------------------------------------------------
BUILD_CTX_DIR="$(mktemp -d)"
readonly BUILD_CTX_DIR
trap 'rm -rf "${BUILD_CTX_DIR}"' EXIT

log "Preparing build context from ${CONFIG_FILE}"

HELPER_OUTPUT="$(python3 "${SCRIPT_DIR}/_build_helper.py" "${CONFIG_FILE}" "${BUILD_CTX_DIR}" "${REPO_ROOT}" "${KIT_ROOT}")"

# _build_helper.py prints KEY=VALUE lines to stdout
IMAGE_NAME=""
while IFS='=' read -r _key _val; do
    case "${_key}" in
        IMAGE_NAME) IMAGE_NAME="${_val}" ;;
    esac
done <<< "${HELPER_OUTPUT}"

[[ -n "${IMAGE_NAME}" ]] || err "Failed to read IMAGE_NAME from _build_helper.py output"
log "Target image: ${IMAGE_NAME}"

# ---------------------------------------------------------------------------
# Check if rebuild is needed
# ---------------------------------------------------------------------------
LOCK_FILE="${KIT_ROOT}/image.lock"
if [[ -f "${LOCK_FILE}" ]] && [[ "${FORCE_REBUILD}" -eq 0 ]]; then
    log "image.lock exists. Use --force-rebuild to rebuild. Checking image..."
    if docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1; then
        log "Image ${IMAGE_NAME} already exists locally. Skipping build."
        log "Use --force-rebuild to force a rebuild."
        exit 0
    fi
    log "Image not found locally despite image.lock; proceeding with build."
fi

# ---------------------------------------------------------------------------
# Docker build
# ---------------------------------------------------------------------------
BUILT_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

REPO_SOURCE_REV="unknown"
if git -C "${REPO_ROOT}" rev-parse --short HEAD >/dev/null 2>&1; then
    REPO_SOURCE_REV="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
fi

declare -a DOCKER_BUILD_ARGS=(
    buildx build
    --build-arg "BUILT_AT=${BUILT_AT}"
    --build-arg "REPO_SOURCE_REV=${REPO_SOURCE_REV}"
    --tag "${IMAGE_NAME}"
    --file "${BUILD_CTX_DIR}/Dockerfile"
    --load
)

if [[ "${NO_CACHE}" -eq 1 ]]; then
    DOCKER_BUILD_ARGS+=(--no-cache)
fi

DOCKER_BUILD_ARGS+=("${BUILD_CTX_DIR}")

log "Running: docker ${DOCKER_BUILD_ARGS[*]}"
docker "${DOCKER_BUILD_ARGS[@]}"

# ---------------------------------------------------------------------------
# Retrieve built image reference and write image.lock
# ---------------------------------------------------------------------------
IMAGE_REF="$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE_NAME}" 2>/dev/null || true)"
if [[ -z "${IMAGE_REF}" ]]; then
    # Local image not pushed to registry -- use tag@sha256:<id>
    IMAGE_ID="$(docker inspect --format='{{.Id}}' "${IMAGE_NAME}")"
    IMAGE_TAG="${IMAGE_NAME%%@*}"
    IMAGE_REF="${IMAGE_TAG}@${IMAGE_ID}"
fi

cat > "${LOCK_FILE}" <<EOF_LOCK
image_ref: ${IMAGE_REF}
built_at: ${BUILT_AT}
base_image: $(python3 -c "
import sys
for line in open(sys.argv[1]):
    if line.strip().startswith('base_image:'):
        print(line.split(':', 1)[1].strip())
        break
" "${CONFIG_FILE}")
EOF_LOCK

log "Build complete"
log "image_ref:  ${IMAGE_REF}"
log "image.lock: ${LOCK_FILE}"
