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
    echo "[quality][cpp-test] $*" >&2
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

CPP_FILES=()
while IFS= read -r file; do
    CPP_FILES+=("${file}")
done < <(cd "${REPO_ROOT}" && rg --files -g '*.cpp' -g '*.cc' -g '*.cxx' -g '*.hpp' -g '*.h')

if [[ ${#CPP_FILES[@]} -eq 0 ]]; then
    log "SKIP: no C++ files found"
    exit 0
fi

BUILD_DIR="${REPO_ROOT}/build"
readonly BUILD_DIR
if [[ ! -d "${BUILD_DIR}" ]]; then
    fail_or_skip "C++ files detected but ${BUILD_DIR} does not exist for ctest"
fi
if ! command -v ctest >/dev/null 2>&1; then
    fail_or_skip "ctest not found"
fi

log "Running ctest"
ctest --test-dir "${BUILD_DIR}" --output-on-failure

log "PASS"
