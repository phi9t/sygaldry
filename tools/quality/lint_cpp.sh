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
    echo "[quality][cpp-lint] $*" >&2
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

if ! command -v clang-format >/dev/null 2>&1; then
    fail_or_skip "clang-format not found"
fi

log "Running clang-format dry-run"
(cd "${REPO_ROOT}" && clang-format --dry-run --Werror "${CPP_FILES[@]}")

if [[ -f "${REPO_ROOT}/compile_commands.json" ]]; then
    if ! command -v clang-tidy >/dev/null 2>&1; then
        fail_or_skip "clang-tidy not found but compile_commands.json is present"
    fi
    log "Running clang-tidy"
    for file in "${CPP_FILES[@]}"; do
        (cd "${REPO_ROOT}" && clang-tidy "${file}" -p .)
    done
elif [[ "${STRICT}" == "1" ]]; then
    log "ERROR: compile_commands.json not found for clang-tidy checks"
    exit 1
else
    log "WARN: compile_commands.json not found; skipping clang-tidy"
fi

log "PASS"
