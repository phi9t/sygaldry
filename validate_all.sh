#!/bin/bash
#
# CI Validation Script
# ====================
# Runs all static analysis and tests for the Sygaldry repo.
#
# Usage:
#   ./validate_all.sh          # Run all checks
#   ./validate_all.sh --quick  # Skip slow checks (shellcheck)

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

FAILURES=0

log() {
    echo "[validate] $*" >&2
}

section() {
    echo ""
    echo "========================================"
    echo " $*"
    echo "========================================"
}

run_check() {
    local name="$1"
    shift
    if "$@"; then
        log "PASS: ${name}"
    else
        log "FAIL: ${name}"
        ((FAILURES++)) || true
    fi
}

QUICK=false
if [[ "${1:-}" == "--quick" ]]; then
    QUICK=true
fi

# ---- Go checks ----
section "Go: build"
run_check "go build ./cmd/worker" go build -C "${SCRIPT_DIR}/temporal" ./cmd/worker
run_check "go build ./cmd/orchestrate" go build -C "${SCRIPT_DIR}/temporal" ./cmd/orchestrate

section "Go: vet"
run_check "go vet" go vet -C "${SCRIPT_DIR}/temporal" ./...

section "Go: test"
run_check "go test" go test -C "${SCRIPT_DIR}/temporal" -count=1 ./...

# ---- Python checks ----
VENV_DIR="${SCRIPT_DIR}/.venv-lint"
if [[ -d "${VENV_DIR}" ]]; then
    RUFF="${VENV_DIR}/bin/ruff"
    BLACK="${VENV_DIR}/bin/black"

    # Collect Python files (exclude venvs, spack stores, caches)
    py_files=()
    while IFS= read -r -d '' f; do
        py_files+=("$f")
    done < <(find "${SCRIPT_DIR}" -name '*.py' \
        -not -path '*/.venv*' \
        -not -path '*/node_modules/*' \
        -not -path '*/spack_store/*' \
        -not -path '*/.spack-env/*' \
        -not -path '*/__pycache__/*' \
        -print0)

    section "Python: ruff"
    if [[ -x "${RUFF}" ]] && [[ ${#py_files[@]} -gt 0 ]]; then
        run_check "ruff check" "${RUFF}" check "${py_files[@]}"
    else
        log "SKIP: ruff not installed or no Python files"
    fi

    section "Python: black"
    if [[ -x "${BLACK}" ]] && [[ ${#py_files[@]} -gt 0 ]]; then
        run_check "black --check" "${BLACK}" --check --quiet "${py_files[@]}"
    else
        log "SKIP: black not installed or no Python files"
    fi
else
    log "SKIP: Python lint venv not found at ${VENV_DIR}"
    log "  Create with: uv venv ${VENV_DIR} && ${VENV_DIR}/bin/pip install ruff black"
fi

# ---- ShellCheck ----
if [[ "${QUICK}" == "false" ]]; then
    section "Shell: shellcheck"
    SHELLCHECK=""
    if command -v shellcheck >/dev/null 2>&1; then
        SHELLCHECK="shellcheck"
    elif [[ -x /tmp/shellcheck ]]; then
        SHELLCHECK="/tmp/shellcheck"
    fi

    if [[ -n "${SHELLCHECK}" ]]; then
        shell_files=()
        while IFS= read -r -d '' f; do
            shell_files+=("$f")
        done < <(find "${SCRIPT_DIR}" -name '*.sh' \
            -not -path '*/.venv*' \
            -not -path '*/node_modules/*' \
            -not -path '*/.spack-env/*' \
            -not -path '*/spack_store/*' \
            -print0)

        if [[ ${#shell_files[@]} -gt 0 ]]; then
            run_check "shellcheck" "${SHELLCHECK}" -s bash -S warning "${shell_files[@]}" \
                -e SC2034  # Ignore unused variable warnings for config constants
        fi
    else
        log "SKIP: shellcheck not found"
    fi
fi

# ---- Summary ----
section "Summary"
if [[ ${FAILURES} -eq 0 ]]; then
    log "All checks passed."
    exit 0
else
    log "${FAILURES} check(s) failed."
    exit 1
fi
