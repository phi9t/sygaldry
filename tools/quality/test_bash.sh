#!/usr/bin/env bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT
STRICT="${QUALITY_STRICT:-0}"
if [[ "${1:-}" == "--strict" ]]; then
    STRICT=1
fi

log() {
    echo "[quality][bash-test] $*" >&2
}

fail_or_skip() {
    local message="$1"
    if [[ "${STRICT}" == "1" ]]; then
        log "ERROR: ${message}"
        exit 1
    fi
    log "SKIP: ${message}"
    exit 0
}

if ! command -v bash >/dev/null 2>&1; then
    fail_or_skip "bash not found"
fi

SH_FILES=()
while IFS= read -r file; do
    SH_FILES+=("${file}")
done < <(cd "${REPO_ROOT}" && rg --files -g '*.sh')

if [[ ${#SH_FILES[@]} -eq 0 ]]; then
    log "SKIP: no shell scripts found"
    exit 0
fi

log "Running bash -n syntax checks"
(cd "${REPO_ROOT}" && bash -n "${SH_FILES[@]}")

log "PASS"
