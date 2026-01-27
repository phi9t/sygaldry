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
    echo "[quality][python-test] $*" >&2
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

VENV_DIR="${REPO_ROOT}/.venv-lint"
readonly VENV_DIR
PYTEST="${VENV_DIR}/bin/pytest"
if [[ ! -x "${PYTEST}" ]]; then
    fail_or_skip "pytest not found at ${PYTEST}"
fi

PYTEST_ARGS=(
    --ignore=pkg
    --ignore=llm_speculative_decoding_gpt2_test.py
    --ignore=tools/qwen3_scale_test.py
    -q
)

log "Running pytest"
set +e
(cd "${REPO_ROOT}" && "${PYTEST}" "${PYTEST_ARGS[@]}")
status=$?
set -e
if [[ ${status} -eq 5 ]]; then
    log "SKIP: no host-safe Python tests collected"
    exit 0
fi
if [[ ${status} -ne 0 ]]; then
    log "ERROR: pytest failed with status ${status}"
    exit "${status}"
fi

log "PASS"
