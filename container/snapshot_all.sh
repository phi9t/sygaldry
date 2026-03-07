#!/bin/bash
#
# End-to-end Snapshot Pipeline
# =============================
#
# Chains spack + mlsys snapshot builds with optional push.
#
# USAGE:
#   ./container/snapshot_all.sh                        # Build spack + all MLSys
#   ./container/snapshot_all.sh spack                  # Build only spack snapshot
#   ./container/snapshot_all.sh vllm sglang            # Build specific MLSys images
#   ./container/snapshot_all.sh all                    # Build everything (explicit)
#   ./container/snapshot_all.sh --push spack vllm      # Build + push specific targets
#   ./container/snapshot_all.sh --dry-run              # Show commands only
#   ./container/snapshot_all.sh --no-verify            # Skip post-build verification
#
# TARGETS:
#   spack              Spack store snapshot (prerequisite for MLSys images)
#   hf-transformers    HuggingFace transformers + tokenizers + accelerate
#   hf-datasets        HuggingFace datasets (isolated)
#   vllm               vLLM inference serving
#   sglang             sglang inference serving
#   torchtitan         TorchTitan distributed training
#   megatronlm         Megatron-Core distributed training
#   llm-serving-all    All LLM serving venvs in one image
#   all                Build spack + all MLSys targets (default)

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/snapshot_common.sh"

readonly ALL_MLSYS_ENVS=(hf-transformers hf-datasets vllm sglang torchtitan megatronlm llm-serving-all)

# ============================================================================
# Argument parsing
# ============================================================================

DRY_RUN=false
PUSH=false
VERIFY=true
TARGETS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true; shift ;;
        --push)      PUSH=true; shift ;;
        --no-verify) VERIFY=false; shift ;;
        --help|-h)
            sed -n '/^# USAGE/,/^set -/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        -*)
            echo "Unknown flag: $1" >&2
            exit 2
            ;;
        *)
            TARGETS+=("$1")
            shift
            ;;
    esac
done

# Default: build everything
if [[ ${#TARGETS[@]} -eq 0 ]] || [[ "${TARGETS[0]:-}" == "all" ]]; then
    TARGETS=(spack "${ALL_MLSYS_ENVS[@]}")
fi

# ============================================================================
# Resolve build stages
# ============================================================================

BUILD_SPACK=false
BUILD_MLSYS=()

for t in "${TARGETS[@]}"; do
    if [[ "${t}" == "spack" ]]; then
        BUILD_SPACK=true
    elif [[ "${t}" == "all" ]]; then
        BUILD_SPACK=true
        BUILD_MLSYS=("${ALL_MLSYS_ENVS[@]}")
    else
        BUILD_MLSYS+=("${t}")
    fi
done

# Build flags to pass through
PASSTHROUGH=()
[[ "${DRY_RUN}" == "true" ]] && PASSTHROUGH+=(--dry-run)
[[ "${PUSH}" == "true" ]]    && PASSTHROUGH+=(--push)
[[ "${VERIFY}" == "false" ]] && PASSTHROUGH+=(--no-verify)

# ============================================================================
# Stage 1: Spack snapshot
# ============================================================================

SPACK_OK=true

if [[ "${BUILD_SPACK}" == "true" ]]; then
    snapshot_log "=== Stage 1: Spack snapshot ==="
    if ! "${SCRIPT_DIR}/snapshot_spack.sh" "${PASSTHROUGH[@]}"; then
        snapshot_error "Spack snapshot failed"
        SPACK_OK=false
    fi
fi

# ============================================================================
# Stage 2: MLSys images
# ============================================================================

MLSYS_RESULTS=()

if [[ ${#BUILD_MLSYS[@]} -gt 0 ]]; then
    if [[ "${BUILD_SPACK}" == "true" ]] && [[ "${SPACK_OK}" == "false" ]] && [[ "${DRY_RUN}" == "false" ]]; then
        snapshot_log "Skipping MLSys builds: spack stage failed"
    else
        for env_name in "${BUILD_MLSYS[@]}"; do
            snapshot_log ""
            snapshot_log "=== Stage 2: MLSys image: ${env_name} ==="
            if "${SCRIPT_DIR}/snapshot_mlsys.sh" "${env_name}" "${PASSTHROUGH[@]}"; then
                MLSYS_RESULTS+=("  OK:   ${env_name}")
            else
                MLSYS_RESULTS+=("  FAIL: ${env_name}")
            fi
        done
    fi
fi

# ============================================================================
# Summary
# ============================================================================

snapshot_log ""
snapshot_log "=== Build Summary ==="
if [[ "${BUILD_SPACK}" == "true" ]]; then
    if [[ "${SPACK_OK}" == "true" ]]; then
        snapshot_log "  OK:   spack"
    else
        snapshot_log "  FAIL: spack"
    fi
fi
for r in "${MLSYS_RESULTS[@]}"; do
    snapshot_log "${r}"
done

# Exit non-zero if any stage failed
if [[ "${SPACK_OK}" == "false" ]]; then
    exit 1
fi
for r in "${MLSYS_RESULTS[@]}"; do
    if [[ "${r}" == *"FAIL:"* ]]; then
        exit 1
    fi
done

exit 0
