#!/usr/bin/env bash
# Post-install ML validation + uv reuse + log/status checks.

set -euo pipefail

PROJECT_ID="${SYGALDRY_PROJECT_ID:-zephyr-verify}"
REQUIRE_GPU="${SYGALDRY_REQUIRE_GPU:-true}"
RUN_UV="true"
UV_PKG="pytest"
VENV_DIR=""
CONSTRAINTS_FILE=""
EXPECT_JOBS=()

usage() {
  cat <<'USAGE'
Usage: container/verify_epilogue.sh [options]

Options:
  --project-id <id>     Project ID for logs/paths
  --require-gpu         Require GPU for validation (default)
  --no-require-gpu      Do not require GPU
  --skip-uv             Skip uv verification
  --uv-package <name>   Package to install via uv (default: pytest)
  --venv-dir <path>     Venv path inside container (default: /opt/bazel_cache/uv/<project-id>)
  --constraints <path>  Constraints file path inside container
  --expect-job <name>   Expect job status DONE (repeatable)
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
    --skip-uv)
      RUN_UV="false"; shift ;;
    --uv-package)
      UV_PKG="$2"; shift 2 ;;
    --venv-dir)
      VENV_DIR="$2"; shift 2 ;;
    --constraints)
      CONSTRAINTS_FILE="$2"; shift 2 ;;
    --expect-job)
      EXPECT_JOBS+=("$2"); shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage; exit 2 ;;
  esac
 done

if [[ -z "${VENV_DIR}" ]]; then
  VENV_DIR="/opt/bazel_cache/uv/${PROJECT_ID}"
fi
if [[ -z "${CONSTRAINTS_FILE}" ]]; then
  CONSTRAINTS_FILE="${VENV_DIR}/spack-constraints.txt"
fi

REQUIRE_FLAG=""
if [[ "${REQUIRE_GPU}" == "true" ]]; then
  REQUIRE_FLAG="--require-gpu"
fi

# ML validation (torch/jax)
zephyr bash -lc \
  "cd \${SYGALDRY_ROOT:-/workspace}/pkg/zephyr && ./verify.sh ${REQUIRE_FLAG}"

# uv verification
if [[ "${RUN_UV}" == "true" ]]; then
  VENV_DIR="${VENV_DIR}" CONSTRAINTS_FILE="${CONSTRAINTS_FILE}" \
    zephyr --entrypoint=uv-install -- "${UV_PKG}"

  zephyr bash -lc \
    "source ${VENV_DIR}/bin/activate && python \${SYGALDRY_ROOT:-/workspace}/container/verify_uv_spack.py"
fi

# Status + logs checks
HOST_ROOT="/mnt/data_infra/zephyr_container_infra/${PROJECT_ID}"
STATUS_DIR="${HOST_ROOT}/bazel_cache/zephyr_jobs"
LOG_DIR="${HOST_ROOT}/logs"

if [[ ${#EXPECT_JOBS[@]} -gt 0 ]]; then
  for job in "${EXPECT_JOBS[@]}"; do
    status_file="${STATUS_DIR}/${job}.status"
    if [[ ! -f "${status_file}" ]]; then
      echo "Missing status file: ${status_file}" >&2
      exit 1
    fi
    line="$(tail -n 1 "${status_file}")"
    case "${line}" in
      DONE*) ;; 
      *)
        echo "Job ${job} not DONE: ${line}" >&2
        exit 1
        ;;
    esac
    if ! ls "${LOG_DIR}/${job}-"*.log >/dev/null 2>&1; then
      echo "Missing log for job ${job} in ${LOG_DIR}" >&2
      exit 1
    fi
  done
else
  if ! ls "${LOG_DIR}"/*.log >/dev/null 2>&1; then
    echo "No logs found in ${LOG_DIR}" >&2
    exit 1
  fi
fi
