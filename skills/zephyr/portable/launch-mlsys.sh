#!/bin/bash
# Thin wrapper for vendored runtime kits in target repos.
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
KIT_ROOT="${REPO_ROOT}/.codex-zephyr-mlsys"
readonly KIT_ROOT

if [[ ! -x "${KIT_ROOT}/bin/launch-mlsys.sh" ]]; then
    echo "ERROR: runtime launcher not found at ${KIT_ROOT}/bin/launch-mlsys.sh" >&2
    echo "Install runtime kit first with zephyr_mlsys_vendor.sh install" >&2
    exit 1
fi

exec "${KIT_ROOT}/bin/launch-mlsys.sh" "$@"
