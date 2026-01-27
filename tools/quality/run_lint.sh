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

run_check() {
    local name="$1"
    shift
    echo "[quality][lint] ${name}" >&2
    if "$@"; then
        echo "[quality][lint] PASS: ${name}" >&2
    else
        echo "[quality][lint] FAIL: ${name}" >&2
        ((FAILURES++)) || true
    fi
}

run_check "Rust" "${SCRIPT_DIR}/lint_rust.sh"
run_check "Python" "${SCRIPT_DIR}/lint_python.sh"
run_check "Go" "${SCRIPT_DIR}/lint_go.sh"
run_check "C++" "${SCRIPT_DIR}/lint_cpp.sh"
run_check "Bash" "${SCRIPT_DIR}/lint_bash.sh"

if [[ ${FAILURES} -gt 0 ]]; then
    echo "[quality][lint] ${FAILURES} check(s) failed" >&2
    exit 1
fi

echo "[quality][lint] All checks passed" >&2
