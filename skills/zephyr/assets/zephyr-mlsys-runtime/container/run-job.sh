#!/bin/bash
# In-container job runner for MLSys images.
#
# Activates the venv, optionally logs stdout/stderr, then runs the command.
# This script is COPYed into the image at /opt/mlsys-run-job.sh.
#
# Usage:
#   run-job.sh [--log <job-name>] -- <command...>
#   run-job.sh <command...>
set -eu -o pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME}:${BASH_LINENO[0]}] $*" >&2
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
LOG_JOB=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --log)
            LOG_JOB="${2:?--log requires a job name}"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            log "Unknown option: $1"
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 1 ]]; then
    echo "Usage: run-job.sh [--log <job-name>] [--] <command...>" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Environment setup
# ---------------------------------------------------------------------------
export SYGALDRY_IN_CONTAINER=1

VENV="${MLSYS_VENV_PATH:-/opt/repo-venv}"
if [[ -d "${VENV}" ]] && [[ -f "${VENV}/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "${VENV}/bin/activate"
fi

# ---------------------------------------------------------------------------
# Run command
# ---------------------------------------------------------------------------
if [[ -n "${LOG_JOB}" ]]; then
    LOG_DIR="/repo/.zephyr-mlsys/logs"
    mkdir -p "${LOG_DIR}"
    LOG_FILE="${LOG_DIR}/${LOG_JOB}.log"
    log "Logging to ${LOG_FILE}"
    exec "$@" > >(tee -a "${LOG_FILE}") 2>&1
else
    exec "$@"
fi
