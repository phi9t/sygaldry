#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  zephyr_job_run.sh --project-id <id> --job-name <name> -- <command-string>

Notes:
- <command-string> is executed inside the Zephyr container via: bash -lc "<command-string>"
- Use a single command string (quote it) so it reaches bash -lc intact.
- Status is written to: /opt/bazel_cache/zephyr_jobs/<job>.status (inside container)
- Logs are written to:  /mnt/data_infra/zephyr_container_infra/<project_id>/logs/<job>-<timestamp>.log

Examples:
  zephyr_job_run.sh --project-id zephyr-a --job-name torch-train -- \
    "cd /workspace/pkg/zephyr && spack env activate . && python train.py"
USAGE
}

PROJECT_ROOT_DEFAULT="/mnt/data_infra/workspace/sygaldry"
PROJECT_ROOT="${PROJECT_ROOT_DEFAULT}"
PROJECT_ID=""
JOB_NAME=""
ENTRYPOINT="default"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      PROJECT_ROOT="$2"; shift 2 ;;
    --project-id)
      PROJECT_ID="$2"; shift 2 ;;
    --job-name)
      JOB_NAME="$2"; shift 2 ;;
    --entrypoint)
      ENTRYPOINT="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    *)
      echo "Unknown argument: $1" >&2
      usage; exit 2 ;;
  esac
done

if [[ -z "${PROJECT_ID}" || -z "${JOB_NAME}" ]]; then
  usage; exit 2
fi

if [[ $# -lt 1 ]]; then
  echo "Missing command string after --" >&2
  usage; exit 2
fi

COMMAND_STRING="$1"

if [[ ! -x "${PROJECT_ROOT}/container/launch_container.sh" ]]; then
  echo "launch_container.sh not found or not executable at: ${PROJECT_ROOT}/container/launch_container.sh" >&2
  exit 1
fi

HOST_ROOT="/mnt/data_infra/zephyr_container_infra/${PROJECT_ID}"
LOG_DIR="${HOST_ROOT}/logs"
HOST_BAZEL_CACHE="${HOST_ROOT}/bazel_cache"
STATUS_DIR_HOST="${HOST_BAZEL_CACHE}/zephyr_jobs"
STATUS_FILE_CONTAINER="/opt/bazel_cache/zephyr_jobs/${JOB_NAME}.status"

mkdir -p "${LOG_DIR}" "${STATUS_DIR_HOST}"

TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/${JOB_NAME}-${TS}.log"
PID_FILE="${LOG_DIR}/${JOB_NAME}-${TS}.pid"

# Wrapper that runs inside the container
read -r -d '' WRAP_BODY <<'WRAP' || true
set -euo pipefail
JOB_NAME="${JOB_NAME}"
STATUS_FILE="${STATUS_FILE}"
COMMAND_STRING="${COMMAND_STRING}"

start_ts="$(date -Is)"
heartbeat_interval=300

echo "START job=${JOB_NAME} ts=${start_ts}" | tee "${STATUS_FILE}"

heartbeat() {
  while true; do
    now="$(date -Is)"
    echo "PROGRESS job=${JOB_NAME} ts=${now} msg=running" | tee "${STATUS_FILE}"
    sleep "${heartbeat_interval}"
  done
}

heartbeat &
HB_PID=$!

set +e
bash -lc "${COMMAND_STRING}"
RC=$?
set -e

kill "${HB_PID}" 2>/dev/null || true
end_ts="$(date -Is)"
if [[ $RC -eq 0 ]]; then
  echo "DONE job=${JOB_NAME} ts=${end_ts} rc=0" | tee "${STATUS_FILE}"
else
  echo "FAILED job=${JOB_NAME} ts=${end_ts} rc=${RC}" | tee "${STATUS_FILE}"
fi
exit "${RC}"
WRAP

WRAP_B64=$(printf '%s' "${WRAP_BODY}" | base64 | tr -d '\n')

q_job=$(printf '%q' "${JOB_NAME}")
q_status=$(printf '%q' "${STATUS_FILE_CONTAINER}")
q_cmd=$(printf '%q' "${COMMAND_STRING}")

RUNNER_CMD="export JOB_NAME=${q_job} STATUS_FILE=${q_status} COMMAND_STRING=${q_cmd}; echo ${WRAP_B64} | base64 -d | bash"

# Run container in background with logging
nohup env \
  SYGALDRY_PROJECT_ID="${PROJECT_ID}" \
  SYGALDRY_ENTRYPOINT="${ENTRYPOINT}" \
  "${PROJECT_ROOT}/container/launch_container.sh" \
  bash -lc "${RUNNER_CMD}" \
  >"${LOG_FILE}" 2>&1 &

JOB_PID=$!
echo "${JOB_PID}" > "${PID_FILE}"

cat <<EOM
Started job: ${JOB_NAME}
Project ID:  ${PROJECT_ID}
PID:         ${JOB_PID}
Log:         ${LOG_FILE}
Status file: ${STATUS_DIR_HOST}/${JOB_NAME}.status
EOM
