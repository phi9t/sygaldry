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
    echo "[quality][test] ${name}" >&2
    if "$@"; then
        echo "[quality][test] PASS: ${name}" >&2
    else
        echo "[quality][test] FAIL: ${name}" >&2
        ((FAILURES++)) || true
    fi
}

run_check "Rust" "${SCRIPT_DIR}/test_rust.sh"
run_check "Python" "${SCRIPT_DIR}/test_python.sh"
run_check "Go" "${SCRIPT_DIR}/test_go.sh"
run_check "C++" "${SCRIPT_DIR}/test_cpp.sh"
run_check "Bash" "${SCRIPT_DIR}/test_bash.sh"

if [[ ${FAILURES} -gt 0 ]]; then
    echo "[quality][test] ${FAILURES} check(s) failed" >&2
    exit 1
fi

echo "[quality][test] All checks passed" >&2
