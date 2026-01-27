#!/usr/bin/env bash
# Host + container preflight checks (Docker + GPU).
# This is a GPU-only container infrastructure - GPU is always required.

set -euo pipefail

PROJECT_ID="${SYGALDRY_PROJECT_ID:-zephyr-verify}"
FIX_GPU="${SYGALDRY_FIX_GPU:-false}"
REQUIRED_CUDA_VERSION="${SYGALDRY_REQUIRED_CUDA_VERSION:-12.9}"

usage() {
  cat <<'USAGE'
Usage: container/verify_preflight.sh [options]

Options:
  --project-id <id>     Project ID for storage checks
  --fix-gpu             Attempt host GPU fixes if diagnostics fail
  --no-fix-gpu          Do not attempt host GPU fixes (default)

Note: This is a GPU-only container infrastructure. GPU is always required.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      PROJECT_ID="$2"; shift 2 ;;
    --fix-gpu)
      FIX_GPU="true"; shift ;;
    --no-fix-gpu)
      FIX_GPU="false"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage; exit 2 ;;
  esac
 done

log() {
  echo "[preflight] $*" >&2
}

# Docker preflight
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon not running or not accessible" >&2
  exit 1
fi

# Storage layout
ROOT="/mnt/data_infra/zephyr_container_infra/${PROJECT_ID}"
DIRS=(
  "${ROOT}/monorepo_home"
  "${ROOT}/spack_store"
  "${ROOT}/bazel_cache"
  "${ROOT}/hf_cache"
  "${ROOT}/config"
  "${ROOT}/logs"
)
for d in "${DIRS[@]}"; do
  mkdir -p "${d}"
  if [[ ! -w "${d}" ]]; then
    echo "Not writable: ${d}" >&2
    exit 1
  fi
 done

# Host GPU diagnostics (GPU is always required)
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/inspect_nvidia_setup.sh" || true
if ! "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/diagnose_nvidia.sh" --test; then
  log "Host GPU diagnostics failed"
  if [[ "${FIX_GPU}" == "true" ]]; then
    if [[ $EUID -eq 0 ]]; then
      "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/diagnose_nvidia.sh" --fix
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo -n "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/diagnose_nvidia.sh" --fix
    else
      echo "GPU fix requested but no sudo/root available" >&2
      exit 1
    fi
  else
    exit 1
  fi
fi

# Container GPU preflight
exec env \
  SYGALDRY_PROJECT_ID="${PROJECT_ID}" \
  SYGALDRY_BUILD_IMAGE="never" \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/launch_container.sh" \
  --entrypoint=verify-gpu
