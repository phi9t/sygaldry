#!/bin/bash
#
# MLSys Baked Venv Image Builder
# ================================
#
# Builds Docker images with pre-baked UV venvs (vLLM, sglang, HF, etc.)
# on top of the Spack snapshot image. Zero runtime build step — users can
# docker run and immediately have a working environment.
#
# USAGE:
#   ./container/snapshot_mlsys.sh vllm                  # Build sygaldry/zephyr:vllm
#   ./container/snapshot_mlsys.sh sglang                # Build sygaldry/zephyr:sglang
#   ./container/snapshot_mlsys.sh hf-transformers       # Build sygaldry/zephyr:hf
#   ./container/snapshot_mlsys.sh llm-serving-all       # Build sygaldry/zephyr:mlsys
#   ./container/snapshot_mlsys.sh all                   # Build all envs
#   ./container/snapshot_mlsys.sh vllm --no-verify      # Skip GPU verification
#   ./container/snapshot_mlsys.sh vllm --push           # Build + verify + push to GHCR
#   ./container/snapshot_mlsys.sh vllm --dry-run        # Show commands only
#
# PREREQUISITES:
#   - Docker with BuildKit support
#   - sygaldry/zephyr:spack snapshot image (label sygaldry.spack.baked=true)
#   - skills/zephyr/envs/<env>.yaml must exist
#
# ENVIRONMENT VARIABLES:
#   SYGALDRY_SNAPSHOT_IMAGE  - Spack snapshot image (default: sygaldry/zephyr:spack)
#   GITHUB_TOKEN             - GitHub token for GHCR auth (optional)
#

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT

# ============================================================================
# Configuration
# ============================================================================

readonly SNAPSHOT_IMAGE="${SYGALDRY_SNAPSHOT_IMAGE:-sygaldry/zephyr:spack}"
readonly ENVS_DIR="${PROJECT_ROOT}/skills/zephyr/envs"

# Tag mapping: env-name → docker tag suffix
declare -A TAG_MAP=(
    [hf-transformers]=hf
    [hf-datasets]=hf-datasets
    [vllm]=vllm
    [sglang]=sglang
    [torchtitan]=torchtitan
    [megatronlm]=megatronlm
    [llm-serving-all]=mlsys
)

# All buildable envs (order matters for "all" target)
readonly ALL_ENVS=(hf-transformers hf-datasets vllm sglang torchtitan megatronlm llm-serving-all)

DRY_RUN=false
VERIFY=true
PUSH=false
readonly REGISTRY="ghcr.io/phi9t/sygaldry"

# ============================================================================
# Helpers
# ============================================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [snapshot-mlsys:${BASH_LINENO[0]}] $*" >&2
}

error() {
    log "ERROR: $*"
    exit 1
}

# ============================================================================
# Argument parsing
# ============================================================================

ENV_TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
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
            echo "Usage: $0 <env-name|all> [--dry-run] [--no-verify] [--push]"
            echo ""
            echo "Build baked MLSys venv images on top of the Spack snapshot."
            echo ""
            echo "Environments:"
            echo "  hf-transformers    HuggingFace transformers + tokenizers + accelerate"
            echo "  hf-datasets        HuggingFace datasets (isolated)"
            echo "  vllm               vLLM inference serving"
            echo "  sglang             sglang inference serving"
            echo "  torchtitan         TorchTitan distributed training (Meta)"
            echo "  megatronlm         Megatron-Core distributed training (NVIDIA)"
            echo "  llm-serving-all    All LLM serving (hf, vllm, sglang) in separate venvs"
            echo "  all                Build all of the above"
            echo ""
            echo "Options:"
            echo "  --dry-run          Show the docker build command without executing"
            echo "  --verify           Run post-build GPU verification (default: on)"
            echo "  --no-verify        Skip post-build verification"
            echo "  --push             Push to GHCR after build+verify"
            echo ""
            echo "Environment variables:"
            echo "  SYGALDRY_SNAPSHOT_IMAGE   Spack snapshot image (default: sygaldry/zephyr:spack)"
            echo "  GITHUB_TOKEN              GitHub token for GHCR auth (optional)"
            exit 0
            ;;
        --registry|--registry=*)
            error "--registry is no longer supported; publish is GHCR-only (${REGISTRY})"
            ;;
        -*)
            error "Unknown flag: $1"
            ;;
        *)
            [[ -n "${ENV_TARGET}" ]] && error "Multiple env targets not supported; use 'all' to build everything"
            ENV_TARGET="$1"
            shift
            ;;
    esac
done

if [[ -z "${ENV_TARGET}" ]]; then
    echo "Usage: $0 <env-name|all> [--dry-run] [--no-verify] [--push]" >&2
    exit 2
fi

readonly DRY_RUN
readonly VERIFY
readonly PUSH

# ============================================================================
# Resolve build list
# ============================================================================

BUILD_LIST=()

if [[ "${ENV_TARGET}" == "all" ]]; then
    BUILD_LIST=("${ALL_ENVS[@]}")
else
    # Validate env target
    if [[ -z "${TAG_MAP[${ENV_TARGET}]+x}" ]]; then
        error "Unknown env: ${ENV_TARGET}. Valid envs: ${ALL_ENVS[*]} all"
    fi
    BUILD_LIST=("${ENV_TARGET}")
fi

# ============================================================================
# Validate prerequisites
# ============================================================================

log "Validating prerequisites..."

# Snapshot image
if ! docker image inspect "${SNAPSHOT_IMAGE}" >/dev/null 2>&1; then
    error "Spack snapshot image '${SNAPSHOT_IMAGE}' not found. Build it first with snapshot_spack.sh."
fi

baked_label="$(docker inspect --format='{{index .Config.Labels "sygaldry.spack.baked"}}' "${SNAPSHOT_IMAGE}" 2>/dev/null || echo "")"
if [[ "${baked_label}" != "true" ]]; then
    log "WARNING: Image '${SNAPSHOT_IMAGE}' does not have sygaldry.spack.baked=true label"
fi
log "  Snapshot image: ${SNAPSHOT_IMAGE} (found, $(docker image inspect "${SNAPSHOT_IMAGE}" --format='{{.Size}}' | awk '{printf "%.1f GB", $1/1073741824}'))"

# Env YAML files
for env in "${BUILD_LIST[@]}"; do
    if [[ ! -f "${ENVS_DIR}/${env}.yaml" ]]; then
        error "Env definition not found: ${ENVS_DIR}/${env}.yaml"
    fi
done
log "  Env definitions: OK (${BUILD_LIST[*]})"

# Override files
for f in nvidia_overrides.txt llm_serving_overrides.txt spack_owned_packages.conf; do
    if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
        error "Missing: ${SCRIPT_DIR}/${f}"
    fi
done
log "  Override/constraint files: OK"

# BuildKit
if ! docker buildx version >/dev/null 2>&1; then
    log "  WARNING: docker buildx not found; falling back to DOCKER_BUILDKIT=1"
fi

log ""

# ============================================================================
# Build loop
# ============================================================================

BUILT_IMAGES=()
FAILED_ENVS=()

for env in "${BUILD_LIST[@]}"; do
    tag_suffix="${TAG_MAP[${env}]}"
    local_tag="sygaldry/zephyr:${tag_suffix}"
    date_tag="sygaldry/zephyr:${tag_suffix}-$(date +%Y%m%d)"

    log "=============================================="
    log "Building: ${env} -> ${local_tag}"
    log "=============================================="
    log ""

    build_cmd=(
        docker build
        --file "${SCRIPT_DIR}/mlsys_venv.dockerfile"
        --build-arg "SPACK_SNAPSHOT_IMAGE=${SNAPSHOT_IMAGE}"
        --build-arg "MLSYS_ENV=${env}"
        --build-arg "VENV_ROOT=/opt/mlsys-envs"
        --tag "${local_tag}"
        --tag "${date_tag}"
        "${PROJECT_ROOT}"
    )

    log "Build command:"
    log "  DOCKER_BUILDKIT=1 ${build_cmd[*]}"
    log ""

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "Dry run -- not executing."
        log ""
        continue
    fi

    log "Building ${local_tag} (this may take 5-15 minutes for UV installs)..."
    log ""

    export DOCKER_BUILDKIT=1
    if ! "${build_cmd[@]}"; then
        log "FAIL: Build failed for ${env}"
        FAILED_ENVS+=("${env}")
        continue
    fi

    log ""
    log "Build succeeded: ${local_tag}"

    # Report size
    image_size="$(docker image inspect "${local_tag}" --format='{{.Size}}' 2>/dev/null || echo "unknown")"
    if [[ "${image_size}" != "unknown" ]]; then
        image_size_gb="$(echo "scale=1; ${image_size} / 1073741824" | bc 2>/dev/null || echo "${image_size}")"
        log "Image size: ${image_size_gb} GB"
    fi

    # Verify labels
    mlsys_label="$(docker inspect --format='{{index .Config.Labels "sygaldry.mlsys.baked"}}' "${local_tag}" 2>/dev/null || echo "")"
    if [[ "${mlsys_label}" == "true" ]]; then
        log "Label sygaldry.mlsys.baked=true verified"
    else
        log "WARNING: sygaldry.mlsys.baked label not found on image"
    fi

    # -------------------------------------------------------------------
    # Post-build verification
    # -------------------------------------------------------------------

    if [[ "${VERIFY}" == "true" ]]; then
        log ""
        log "Running post-build verification..."
        if bash "${SCRIPT_DIR}/verify_mlsys.sh" "${local_tag}"; then
            log "Verification PASSED for ${local_tag}"
        else
            log "FAIL: Verification failed for ${local_tag}"
            FAILED_ENVS+=("${env}")
            continue
        fi
    else
        log "Verification skipped (--no-verify)."
    fi

    # -------------------------------------------------------------------
    # Push to registry
    # -------------------------------------------------------------------

    if [[ "${PUSH}" == "true" ]]; then
        log ""
        log "Pushing ${local_tag} to registry..."

        REGISTRY_HOST="ghcr.io"

        # Check registry auth
        if ! docker login "${REGISTRY_HOST}" --get-login >/dev/null 2>&1; then
            if [[ -n "${GITHUB_TOKEN:-}" ]]; then
                log "Authenticating to ghcr.io with GITHUB_TOKEN..."
                echo "${GITHUB_TOKEN}" | docker login ghcr.io -u "$(echo "${REGISTRY}" | cut -d/ -f2)" --password-stdin
            else
                error "Not authenticated to ${REGISTRY_HOST}. Run: docker login ${REGISTRY_HOST}"
            fi
        fi

        remote_tag="${REGISTRY}/zephyr:${tag_suffix}"
        remote_date_tag="${REGISTRY}/zephyr:${tag_suffix}-$(date +%Y%m%d)"

        log "Tagging:"
        log "  ${local_tag} -> ${remote_tag}"
        log "  ${local_tag} -> ${remote_date_tag}"

        docker tag "${local_tag}" "${remote_tag}"
        docker tag "${local_tag}" "${remote_date_tag}"

        log "Pushing ${remote_tag}..."
        if ! docker push "${remote_tag}"; then
            log "FAIL: Push failed for ${remote_tag}"
            FAILED_ENVS+=("${env}")
            continue
        fi

        log "Pushing ${remote_date_tag}..."
        if ! docker push "${remote_date_tag}"; then
            log "FAIL: Push failed for ${remote_date_tag}"
            FAILED_ENVS+=("${env}")
            continue
        fi

        log "Push complete: ${remote_tag}, ${remote_date_tag}"
    fi

    BUILT_IMAGES+=("${local_tag}")
    log ""
done

# ============================================================================
# Summary
# ============================================================================

if [[ "${DRY_RUN}" == "true" ]]; then
    log "Dry run complete. No images were built."
    exit 0
fi

log ""
log "=============================================="
log " MLSys Image Build Summary"
log "=============================================="
log " Built:   ${#BUILT_IMAGES[@]}"
for img in "${BUILT_IMAGES[@]}"; do
    log "   - ${img}"
done
if [[ ${#FAILED_ENVS[@]} -gt 0 ]]; then
    log " Failed:  ${#FAILED_ENVS[@]}"
    for env in "${FAILED_ENVS[@]}"; do
        log "   - ${env}"
    done
fi
log "=============================================="
log ""

# Usage hints
if [[ ${#BUILT_IMAGES[@]} -gt 0 ]]; then
    first_img="${BUILT_IMAGES[0]}"
    log "Usage:"
    log ""
    log "  # Standalone (venv auto-activates):"
    log "  docker run --rm -it --gpus all ${first_img}"
    log ""
    log "  # Via launcher:"
    log "  SYGALDRY_IMAGE=${first_img} ./container/launch_container.sh"
    log ""
fi

if [[ ${#FAILED_ENVS[@]} -gt 0 ]]; then
    exit 1
fi
