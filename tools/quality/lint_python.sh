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
    echo "[quality][python-lint] $*" >&2
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
RUFF="${VENV_DIR}/bin/ruff"
BLACK="${VENV_DIR}/bin/black"

if [[ ! -x "${RUFF}" ]]; then
    fail_or_skip "ruff not found at ${RUFF}; create .venv-lint and install lint deps"
fi
if [[ ! -x "${BLACK}" ]]; then
    fail_or_skip "black not found at ${BLACK}; create .venv-lint and install lint deps"
fi

PY_FILES=()
while IFS= read -r -d '' file; do
    PY_FILES+=("${file}")
done < <(find "${REPO_ROOT}" -name '*.py' \
    -not -path '*/.venv*' \
    -not -path '*/node_modules/*' \
    -not -path '*/spack_store/*' \
    -not -path '*/.spack-env/*' \
    -not -path '*/__pycache__/*' \
    -print0)

if [[ ${#PY_FILES[@]} -eq 0 ]]; then
    log "SKIP: no Python files found"
    exit 0
fi

log "Running ruff"
"${RUFF}" check "${PY_FILES[@]}"

log "Running black --check"
"${BLACK}" --check "${PY_FILES[@]}"

log "PASS"
