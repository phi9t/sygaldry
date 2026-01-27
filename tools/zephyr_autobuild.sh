#!/usr/bin/env bash
# One-shot Spack build + torch/jax GPU validation inside the Zephyr container.
# Intended to be called by autoretry wrappers or manually.

set -euo pipefail

PROJECT_ID="${SYGALDRY_PROJECT_ID:-zephyr-validate}"
JOB_NAME="${1:-spack-autobuild}"
WORKDIR="/mnt/data_infra/workspace/sygaldry"
LOG_ROOT="/mnt/data_infra/zephyr_container_infra/${PROJECT_ID}"
STATUS_DIR="${LOG_ROOT}/bazel_cache/zephyr_jobs"
STATUS="${STATUS_DIR}/${JOB_NAME}.status"
RAW_LOG_DIR="${LOG_ROOT}/logs"

cd "${WORKDIR}"

# Launch Spack build inside the container (do not nest launch_container.sh)
tools/zephyr_job run --project-id "${PROJECT_ID}" --job "${JOB_NAME}" -- \
  /workspace/container/entrypoints/spack-build.sh

# Wait for status file to appear
sleep 10

wait_status() {
  local file="$1"
  local ok_prefix="$2"
  local fail_prefix="$3"
  local interval="${4:-60}"
  while true; do
    [[ -f "$file" ]] || { sleep "${interval}"; continue; }
    line=$(tail -n1 "$file")
    case "$line" in
      ${ok_prefix}*)   return 0 ;;
      ${fail_prefix}*) return 1 ;;
      *)               sleep "${interval}" ;;
    esac
  done
}

echo "[autobuild] waiting for Spack build to finish..."
wait_status "${STATUS}" "DONE" "FAILED" 120 || {
  echo "[autobuild] build failed; see ${STATUS}"
  exit 1
}

# Build-start detector: confirm Spack actually began compiling; otherwise retry fast.
RAW_LOG_LATEST=$(ls -t "${RAW_LOG_DIR}/${JOB_NAME}-"*.log 2>/dev/null | head -n1 || true)
if [[ -n "${RAW_LOG_LATEST}" ]]; then
  if ! tail -n 400 "${RAW_LOG_LATEST}" | grep -q "==> Installing"; then
    echo "[autobuild] build did not reach install phase; failing fast for retry"
    exit 1
  fi
fi

# Validation: run GPU checks inside container
VAL_JOB="${JOB_NAME}-validate"
tools/zephyr_job run --project-id "${PROJECT_ID}" --job "${VAL_JOB}" -- \
  /workspace/container/entrypoints/verify-gpu.sh

VAL_STATUS="${STATUS_DIR}/${VAL_JOB}.status"
echo "[autobuild] running validation..."
wait_status "${VAL_STATUS}" "DONE" "FAILED" 60 || {
  echo "[autobuild] validation failed; see ${VAL_STATUS}"
  exit 2
}

echo "[autobuild] success"
exit 0
