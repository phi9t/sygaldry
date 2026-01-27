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
    echo "[quality][go-test] $*" >&2
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

if ! command -v go >/dev/null 2>&1; then
    fail_or_skip "go not found"
fi

log "Running go test"
go test -C "${REPO_ROOT}/temporal" -count=1 ./...

log "PASS"
