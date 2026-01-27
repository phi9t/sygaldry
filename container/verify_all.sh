#!/usr/bin/env bash
# End-to-end verification for Zephyr container infra + Spack environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_ID="${SYGALDRY_PROJECT_ID:-zephyr-verify}"
REQUIRE_GPU="${SYGALDRY_REQUIRE_GPU:-true}"
FIX_GPU="${SYGALDRY_FIX_GPU:-true}"
REBUILD_IMAGE="false"
BUILD_POLICY="auto"
USE_AUTORETRY="false"
RUN_SPACK="true"
RUN_UV="true"
UV_PKG="pytest"
JOB_NAME=""
SMOKE="false"
RUN_EPILOGUE="true"

usage() {
  cat <<'USAGE'
Zephyr infra verification

Usage:
  container/verify_all.sh [options]

Options:
  --project-id <id>       Project ID for logs and container isolation
  --require-gpu           Fail fast if GPU unavailable (default: true)
  --no-require-gpu        Do not require GPU
  --fix-gpu               Attempt host GPU fixes if diagnostics fail (default: true)
  --no-fix-gpu            Do not attempt host GPU fixes
  --rebuild-image         Force image rebuild
  --autoretry             Use tools/zephyr_autoretry.sh for Spack installs
  --job-name <name>       Spack build job name
  --skip-spack            Skip Spack install step
  --skip-uv               Skip uv verification step
  --uv-package <name>     Package to install via uv (default: pytest)
  --smoke                 Run lightweight checks only (skip Spack + epilogue)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      PROJECT_ID="$2"; shift 2 ;;
    --require-gpu)
      REQUIRE_GPU="true"; shift ;;
    --no-require-gpu)
      REQUIRE_GPU="false"; shift ;;
    --fix-gpu)
      FIX_GPU="true"; shift ;;
    --no-fix-gpu)
      FIX_GPU="false"; shift ;;
    --rebuild-image)
      REBUILD_IMAGE="true"; shift ;;
    --autoretry)
      USE_AUTORETRY="true"; shift ;;
    --job-name)
      JOB_NAME="$2"; shift 2 ;;
    --skip-spack)
      RUN_SPACK="false"; shift ;;
    --skip-uv)
      RUN_UV="false"; shift ;;
    --uv-package)
      UV_PKG="$2"; shift 2 ;;
    --smoke)
      SMOKE="true"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage; exit 2 ;;
  esac
 done

if [[ "${REBUILD_IMAGE}" == "true" ]]; then
  BUILD_POLICY="always"
fi
if [[ "${SMOKE}" == "true" ]]; then
  BUILD_POLICY="never"
  FIX_GPU="false"
  RUN_SPACK="false"
  RUN_UV="false"
  RUN_EPILOGUE="false"
fi
TS="$(date +%Y%m%d-%H%M%S)"
LOG_ROOT="/mnt/data_infra/zephyr_container_infra/projects/${PROJECT_ID}/logs"
RUN_LOG_DIR="${LOG_ROOT}/infra-verify-${TS}"
SUMMARY_FILE="${RUN_LOG_DIR}/summary.txt"

if [[ -z "${JOB_NAME}" ]]; then
  JOB_NAME="spack-autobuild-${TS}"
fi

mkdir -p "${RUN_LOG_DIR}"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "${SUMMARY_FILE}" >&2
}

run_step() {
  local name="$1"
  shift
  log "==> ${name}"
  if "$@"; then
    log "PASS: ${name}"
    return 0
  fi
  local rc=$?
  log "FAIL: ${name} (rc=${rc})"
  return ${rc}
}

FAILURES=0

log "Zephyr infra verification starting"
log "Project ID: ${PROJECT_ID}"
log "Require GPU: ${REQUIRE_GPU}"
log "Fix GPU: ${FIX_GPU}"
log "Build policy: ${BUILD_POLICY}"
log "Job name: ${JOB_NAME}"
log "Smoke mode: ${SMOKE}"

# Step 0: Host preflight + GPU diagnostics
run_step "Preflight" env \
  SYGALDRY_PROJECT_ID="${PROJECT_ID}" \
  SYGALDRY_REQUIRE_GPU="${REQUIRE_GPU}" \
  SYGALDRY_FIX_GPU="${FIX_GPU}" \
  "${REPO_ROOT}/container/verify_preflight.sh" \
  || ((FAILURES++))

# Step 1: Image build verification
run_step "Image build/verify" env \
  SYGALDRY_PROJECT_ID="${PROJECT_ID}" \
  SYGALDRY_BUILD_IMAGE="${BUILD_POLICY}" \
  "${REPO_ROOT}/container/verify_image_build.sh" \
  || ((FAILURES++))

# Step 3: Spack install (babysit)
if [[ "${RUN_SPACK}" == "true" ]]; then
  if [[ "${USE_AUTORETRY}" == "true" ]]; then
    run_step "Spack install (autoretry)" env \
      SYGALDRY_PROJECT_ID="${PROJECT_ID}" \
      "${REPO_ROOT}/container/verify_build.sh" --project-id "${PROJECT_ID}" --autoretry \
      || ((FAILURES++))
  else
    run_step "Spack install (autobuild)" env \
      SYGALDRY_PROJECT_ID="${PROJECT_ID}" \
      "${REPO_ROOT}/container/verify_build.sh" --project-id "${PROJECT_ID}" --job-name "${JOB_NAME}" \
      || ((FAILURES++))
  fi
else
  log "SKIP: Spack install"
fi

if [[ "${RUN_EPILOGUE}" == "true" ]]; then
  # Step 4: Epilogue validation (ML + uv + logs)
  if [[ "${RUN_UV}" == "true" ]]; then
    run_step "Epilogue (ML + uv + logs)" env \
      SYGALDRY_PROJECT_ID="${PROJECT_ID}" \
      SYGALDRY_REQUIRE_GPU="${REQUIRE_GPU}" \
      "${REPO_ROOT}/container/verify_epilogue.sh" --project-id "${PROJECT_ID}" \
        --uv-package "${UV_PKG}" \
        --expect-job "${JOB_NAME}" --expect-job "${JOB_NAME}-validate" \
      || ((FAILURES++))
  else
    run_step "Epilogue (ML + logs)" env \
      SYGALDRY_PROJECT_ID="${PROJECT_ID}" \
      SYGALDRY_REQUIRE_GPU="${REQUIRE_GPU}" \
      "${REPO_ROOT}/container/verify_epilogue.sh" --project-id "${PROJECT_ID}" \
        --skip-uv --expect-job "${JOB_NAME}" --expect-job "${JOB_NAME}-validate" \
      || ((FAILURES++))
  fi
else
  log "SKIP: Epilogue (smoke mode)"
fi

log "Verification complete. Failures: ${FAILURES}"
log "Summary: ${SUMMARY_FILE}"

if [[ ${FAILURES} -ne 0 ]]; then
  exit 1
fi

exit 0
