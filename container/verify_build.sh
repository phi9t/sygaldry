#!/usr/bin/env bash
# Run Spack install with babysitting.

set -euo pipefail

PROJECT_ID="${SYGALDRY_PROJECT_ID:-zephyr-verify}"
JOB_NAME=""
USE_AUTORETRY="false"

usage() {
  cat <<'USAGE'
Usage: container/verify_build.sh [options]

Options:
  --project-id <id>   Project ID for isolation and logs
  --job-name <name>   Job name for spack build
  --autoretry         Use tools/zephyr_autoretry.sh
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      PROJECT_ID="$2"; shift 2 ;;
    --job-name)
      JOB_NAME="$2"; shift 2 ;;
    --autoretry)
      USE_AUTORETRY="true"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage; exit 2 ;;
  esac
 done

if [[ -z "${JOB_NAME}" ]]; then
  JOB_NAME="spack-autobuild-$(date +%Y%m%d-%H%M%S)"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

if [[ "${USE_AUTORETRY}" == "true" ]]; then
  exec env SYGALDRY_PROJECT_ID="${PROJECT_ID}" \
    "${ROOT}/tools/zephyr_autoretry.sh"
fi

exec env SYGALDRY_PROJECT_ID="${PROJECT_ID}" \
  "${ROOT}/tools/zephyr_autobuild.sh" "${JOB_NAME}"
