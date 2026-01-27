#!/usr/bin/env bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
STRICT="${QUALITY_STRICT:-0}"
if [[ "${1:-}" == "--strict" ]]; then
    STRICT=1
fi

export QUALITY_STRICT="${STRICT}"

FAILURES=0

run_phase() {
    local name="$1"
    shift
    echo "[quality][all] ${name}" >&2
    if "$@"; then
        echo "[quality][all] PASS: ${name}" >&2
    else
        echo "[quality][all] FAIL: ${name}" >&2
        ((FAILURES++)) || true
    fi
}

run_phase "Lint" "${SCRIPT_DIR}/run_lint.sh"
run_phase "Tests" "${SCRIPT_DIR}/run_test.sh"
run_phase "Coverage" "${SCRIPT_DIR}/run_coverage.sh"

if [[ ${FAILURES} -gt 0 ]]; then
    echo "[quality][all] ${FAILURES} phase(s) failed" >&2
    exit 1
fi

echo "[quality][all] All phases passed" >&2
