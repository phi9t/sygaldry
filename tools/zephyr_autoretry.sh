#!/usr/bin/env bash
# Retry loop around zephyr_autobuild.sh with basic remediation and locking.
# Intended to run headless (tmux/systemd-run). Writes high-level log lines to STDOUT.

set -euo pipefail

PROJECT_ID="${SYGALDRY_PROJECT_ID:-zephyr-validate}"
MAX_TRIES="${MAX_TRIES:-12}"           # total attempts before giving up
SLEEP_BETWEEN="${SLEEP_BETWEEN:-900}"  # seconds between attempts (default 15m)
LOCKFILE="/tmp/zephyr_autoretry.lock"
LOG_ROOT="/mnt/data_infra/zephyr_container_infra/${PROJECT_ID}"
JOB_STATUS_DIR="${LOG_ROOT}/bazel_cache/zephyr_jobs"

exec {lockfd}>"${LOCKFILE}"
if ! flock -n "${lockfd}"; then
  echo "[autoretry] another instance is running; exiting"
  exit 0
fi

attempt=1
while (( attempt <= MAX_TRIES )); do
  echo "[autoretry] attempt ${attempt}/${MAX_TRIES} starting"
  if tools/zephyr_autobuild.sh "spack-autobuild-${attempt}"; then
    echo "[autoretry] success on attempt ${attempt}"
    exit 0
  fi

  echo "[autoretry] attempt ${attempt} failed; remediation and retry after sleep"

  # Remediation 1: clear stale status files older than a day
  find "${JOB_STATUS_DIR}" -name "spack-autobuild-*.status" -mtime +1 -delete 2>/dev/null || true

  # Remediation 2: optionally clear stuck build_stage (commented; enable if needed)
  # rm -rf "/mnt/data_infra/zephyr_container_infra/${PROJECT_ID}/spack_store/build_stage/"*

  (( attempt++ ))
  sleep "${SLEEP_BETWEEN}"
done

echo "[autoretry] exhausted attempts (${MAX_TRIES}) without success"
exit 1
