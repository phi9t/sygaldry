#!/bin/bash
# Launch a command inside the hermetic MLSys Docker image.
# Reads image.lock written by build-mlsys.sh.
#
# Usage: launch-mlsys.sh [--ro] [--no-gpu] [--] <command...>
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
KIT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly KIT_ROOT
REPO_ROOT="$(cd "${KIT_ROOT}/.." && pwd)"
readonly REPO_ROOT

LOCK_FILE="${KIT_ROOT}/image.lock"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [launch-mlsys:${BASH_LINENO[0]}] $*" >&2
}

err() {
    log "ERROR: $*"
    exit 1
}

usage() {
    cat <<'USAGE'
Usage:
  launch-mlsys.sh [--ro] [--no-gpu] [--] <command...>

Options:
  --ro       Mount repo read-only inside container (/repo).
  --no-gpu   Skip GPU docker flags (--runtime=nvidia --gpus=all).

Env vars:
  MLSYS_DISABLE_GPU   Set to 1 to skip GPU docker flags (legacy; prefer --no-gpu).

Reads .zephyr-mlsys/image.lock and runs the baked MLSys image.
Run build-mlsys.sh first to create image.lock.
USAGE
}

REPO_RO=0
NO_GPU=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ro)
            REPO_RO=1
            shift
            ;;
        --no-gpu)
            NO_GPU=1
            shift
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            err "Unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 1 ]]; then
    usage
    exit 2
fi

[[ -f "${LOCK_FILE}" ]] || err "image.lock not found: ${LOCK_FILE}
Run build-mlsys.sh first."

# Read image_ref from image.lock (first matching key, strip leading whitespace)
IMAGE_REF=""
while IFS= read -r _line; do
    case "${_line}" in
        image_ref:*)
            IMAGE_REF="${_line#image_ref:}"
            IMAGE_REF="${IMAGE_REF#"${IMAGE_REF%%[! ]*}"}"
            break
            ;;
    esac
done < "${LOCK_FILE}"

[[ -n "${IMAGE_REF}" ]] || err "image_ref not found in ${LOCK_FILE}"

command -v docker >/dev/null 2>&1 || err "docker not found in PATH"

declare -a DOCKER_RUN_ARGS=(--rm)

# GPU support: disabled by --no-gpu flag or MLSYS_DISABLE_GPU=1 env var
if [[ "${NO_GPU}" -eq 0 ]] && [[ "${MLSYS_DISABLE_GPU:-0}" != "1" ]]; then
    DOCKER_RUN_ARGS+=(--runtime=nvidia --gpus=all)
fi

if [[ "${REPO_RO}" -eq 1 ]]; then
    DOCKER_RUN_ARGS+=(-v "${REPO_ROOT}:/repo:ro")
else
    DOCKER_RUN_ARGS+=(-v "${REPO_ROOT}:/repo")
fi

DOCKER_RUN_ARGS+=(-w /repo)

log "image_ref: ${IMAGE_REF}"
exec docker run "${DOCKER_RUN_ARGS[@]}" "${IMAGE_REF}" "$@"
