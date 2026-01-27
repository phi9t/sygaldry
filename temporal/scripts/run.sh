#!/usr/bin/env bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly ROOT_DIR

PLAN_PATH="${1:-}"
if [[ -z "${PLAN_PATH}" ]]; then
  echo "usage: ./scripts/run.sh <plan.yaml>" >&2
  exit 1
fi

if [[ "${PLAN_PATH}" != /* ]]; then
  PLAN_PATH="${ROOT_DIR}/${PLAN_PATH}"
fi

if [[ ! -f "${PLAN_PATH}" ]]; then
  echo "plan file not found: ${PLAN_PATH}" >&2
  exit 1
fi

LOG_DIR="${TEMPORAL_LOG_DIR:-${ROOT_DIR}/logs}"
WORKER_LOG="${WORKER_LOG:-/tmp/temporal-worker.log}"
LOG_MAX_BYTES="${TEMPORAL_LOG_MAX_BYTES:-10000}"

wait_for_temporal() {
  for _ in $(seq 1 60); do
    if (echo > /dev/tcp/127.0.0.1/7233) >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ensure_temporal() {
  if wait_for_temporal; then
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    echo "Starting Temporal via docker compose..."
    (
      cd "${ROOT_DIR}"
      docker compose up -d
    )
  elif command -v temporal >/dev/null 2>&1; then
    echo "Starting Temporal dev server in background..."
    nohup temporal server start-dev --ui-port 8233 >/tmp/temporal-server.log 2>&1 &
  else
    echo "Temporal is not running and neither docker nor temporal CLI is available." >&2
    exit 1
  fi

  if ! wait_for_temporal; then
    echo "Temporal did not become ready on localhost:7233" >&2
    exit 1
  fi
}

ensure_worker() {
  mkdir -p "${LOG_DIR}"

  if pgrep -f "cmd/worker" >/dev/null 2>&1; then
    return 0
  fi

  echo "Starting Temporal worker..."
  (
    cd "${ROOT_DIR}"
    nohup env TEMPORAL_LOG_DIR="${LOG_DIR}" TEMPORAL_LOG_MAX_BYTES="${LOG_MAX_BYTES}" \
      go run ./cmd/worker >"${WORKER_LOG}" 2>&1 &
  )

  sleep 1
  if ! pgrep -f "cmd/worker" >/dev/null 2>&1; then
    echo "failed to start worker (see ${WORKER_LOG})" >&2
    exit 1
  fi
}

main() {
  ensure_temporal
  ensure_worker

  (
    cd "${ROOT_DIR}"
    go run ./cmd/orchestrate run -plan "${PLAN_PATH}" -log-dir "${LOG_DIR}"
  )

  (
    cd "${ROOT_DIR}"
    ./scripts/logs_cli.py --log-dir "${LOG_DIR}" summary --latest
  )
}

main "$@"
