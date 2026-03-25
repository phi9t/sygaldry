#!/usr/bin/env bash
# Verify container image build integrity.

set -euo pipefail

PROJECT_ID="${SYGALDRY_PROJECT_ID:-zephyr-verify}"
BUILD_POLICY="${SYGALDRY_BUILD_IMAGE:-auto}"
REBUILD="false"

usage() {
  cat <<'USAGE'
Usage: container/verify_image_build.sh [--project-id <id>] [--rebuild]

Options:
  --project-id <id>   Project ID for isolation and logs
  --rebuild           Force image rebuild (build policy = always)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      PROJECT_ID="$2"; shift 2 ;;
    --rebuild)
      REBUILD="true"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage; exit 2 ;;
  esac
 done

if [[ "${REBUILD}" == "true" ]]; then
  BUILD_POLICY="always"
fi

if [[ "${BUILD_POLICY}" != "auto" && "${BUILD_POLICY}" != "always" && "${BUILD_POLICY}" != "never" ]]; then
  echo "Invalid build policy: ${BUILD_POLICY}" >&2
  exit 2
fi

exec env \
  SYGALDRY_PROJECT_ID="${PROJECT_ID}" \
  SYGALDRY_BUILD_IMAGE="${BUILD_POLICY}" \
  zephyr \
  --entrypoint=default -- bash -lc "true"
