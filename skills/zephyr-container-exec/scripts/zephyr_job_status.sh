#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  zephyr_job_status.sh --project-id <id> --job-name <name>

Shows:
- last status line
- last 40 log lines
- pid file (if present)
USAGE
}

PROJECT_ID=""
JOB_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      PROJECT_ID="$2"; shift 2 ;;
    --job-name)
      JOB_NAME="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage; exit 2 ;;
  esac
done

if [[ -z "${PROJECT_ID}" || -z "${JOB_NAME}" ]]; then
  usage; exit 2
fi

HOST_ROOT="/mnt/data_infra/zephyr_container_infra/${PROJECT_ID}"
STATUS_FILE="${HOST_ROOT}/bazel_cache/zephyr_jobs/${JOB_NAME}.status"
LOG_DIR="${HOST_ROOT}/logs"

LAST_LOG=$(ls -t "${LOG_DIR}/${JOB_NAME}-"*.log 2>/dev/null | head -n 1 || true)

if [[ -f "${STATUS_FILE}" ]]; then
  echo "Status:"
  tail -n 1 "${STATUS_FILE}"
else
  echo "Status file not found: ${STATUS_FILE}"
fi

if [[ -n "${LAST_LOG}" && -f "${LAST_LOG}" ]]; then
  echo ""
  echo "Log (tail 40): ${LAST_LOG}"
  tail -n 40 "${LAST_LOG}"
else
  echo "Log file not found for job prefix: ${LOG_DIR}/${JOB_NAME}-*.log"
fi

PID_FILE=$(ls -t "${LOG_DIR}/${JOB_NAME}-"*.pid 2>/dev/null | head -n 1 || true)
if [[ -n "${PID_FILE}" && -f "${PID_FILE}" ]]; then
  echo ""
  echo "PID file: ${PID_FILE}"
  cat "${PID_FILE}"
fi
