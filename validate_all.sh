#!/bin/bash
#
# CI Validation Script
# ====================
# Runs all static analysis and tests for the Sygaldry repo.
#
# Usage:
#   ./validate_all.sh                    # Run all checks
#   ./validate_all.sh --quick            # Skip slow checks (shellcheck)
#   ./validate_all.sh --verify-only      # Quick Spack/GPU verification only (no rebuild)
#   ./validate_all.sh --infra            # Include infra smoke verification
#   ./validate_all.sh --infra-full       # Include full infra verification (slow)
#   ./validate_all.sh --multi-repo-unit  # Multi-repo unit tests (no Docker/GPU)
#   ./validate_all.sh --multi-repo       # Multi-repo unit + integration + E2E (Docker+GPU)
#   ./validate_all.sh --snapshot         # Snapshot image verification (T1-T7, GPU)
#   ./validate_all.sh --snapshot-no-gpu  # Snapshot verification without GPU (T1-T4, T7)
#   ./validate_all.sh --uv-layering      # UV+Spack layering verification (GPU, snapshot)
#   ./validate_all.sh --uv-layering-no-gpu  # UV+Spack layering verification (no GPU)
#   ./validate_all.sh --quality-lint     # Run engineering quality lint gates
#   ./validate_all.sh --quality-test     # Run engineering quality test gates
#   ./validate_all.sh --quality-coverage # Run engineering quality coverage gate
#   ./validate_all.sh --quality-all      # Run all engineering quality gates
#   ./validate_all.sh --quality-strict   # Enforce strict mode for quality gates
#   ./validate_all.sh                    # Also runs Zephyr contract anti-drift checks

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
INFRA=false
INFRA_FULL=false
VERIFY_ONLY=false
MULTI_REPO=false
MULTI_REPO_UNIT=false
SNAPSHOT=false
SNAPSHOT_NO_GPU=false
UV_LAYERING=false
UV_LAYERING_NO_GPU=false
QUALITY_LINT=false
QUALITY_TEST=false
QUALITY_COVERAGE=false
QUALITY_ALL=false
QUALITY_STRICT=false
while [[ $# -gt 0 ]]; do
    case "${1}" in
        --quick)
            QUICK=true
            shift
            ;;
        --verify-only)
            VERIFY_ONLY=true
            shift
            ;;
        --infra)
            INFRA=true
            shift
            ;;
        --infra-full)
            INFRA=true
            INFRA_FULL=true
            shift
            ;;
        --multi-repo)
            MULTI_REPO=true
            MULTI_REPO_UNIT=true
            shift
            ;;
        --multi-repo-unit)
            MULTI_REPO_UNIT=true
            shift
            ;;
        --snapshot)
            SNAPSHOT=true
            shift
            ;;
        --snapshot-no-gpu)
            SNAPSHOT=true
            SNAPSHOT_NO_GPU=true
            shift
            ;;
        --uv-layering)
            UV_LAYERING=true
            shift
            ;;
        --uv-layering-no-gpu)
            UV_LAYERING=true
            UV_LAYERING_NO_GPU=true
            shift
            ;;
        --quality-lint)
            QUALITY_LINT=true
            shift
            ;;
        --quality-test)
            QUALITY_TEST=true
            shift
            ;;
        --quality-coverage)
            QUALITY_COVERAGE=true
            shift
            ;;
        --quality-all)
            QUALITY_ALL=true
            shift
            ;;
        --quality-strict)
            QUALITY_STRICT=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# ---- Verify-only mode ----
# Quick verification of Spack packages (PyTorch, JAX) without rebuild
if [[ "${VERIFY_ONLY}" == "true" ]]; then
    section "Spack Verification (fast, no rebuild)"
    log "Running verify-spack.sh entrypoint..."
    if "${SCRIPT_DIR}/container/launch_container.sh" --entrypoint=verify-spack.sh; then
        log "PASS: Spack verification"
        log "All checks passed."
        exit 0
    else
        log "FAIL: Spack verification"
        exit 1
    fi
fi

# ---- Engineering quality mode ----
if [[ "${QUALITY_ALL}" == "true" ]]; then
    QUALITY_LINT=true
    QUALITY_TEST=true
    QUALITY_COVERAGE=true
fi

if [[ "${QUALITY_LINT}" == "true" ]] || [[ "${QUALITY_TEST}" == "true" ]] || [[ "${QUALITY_COVERAGE}" == "true" ]]; then
    QUALITY_ARGS=()
    if [[ "${QUALITY_STRICT}" == "true" ]]; then
        QUALITY_ARGS+=("--strict")
    fi

    section "Engineering Quality Gates"
    if [[ "${QUALITY_LINT}" == "true" ]]; then
        run_check "quality lint" "${SCRIPT_DIR}/tools/quality/run_lint.sh" "${QUALITY_ARGS[@]}"
    fi
    if [[ "${QUALITY_TEST}" == "true" ]]; then
        run_check "quality test" "${SCRIPT_DIR}/tools/quality/run_test.sh" "${QUALITY_ARGS[@]}"
    fi
    if [[ "${QUALITY_COVERAGE}" == "true" ]]; then
        run_check "quality coverage" "${SCRIPT_DIR}/tools/quality/run_coverage.sh" "${QUALITY_ARGS[@]}"
    fi

    section "Summary"
    if [[ ${FAILURES} -eq 0 ]]; then
        log "All checks passed."
        exit 0
    else
        log "${FAILURES} check(s) failed."
        exit 1
    fi
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

    # Collect Python files from git (fast/deterministic); fall back to find.
    py_files=()
    if git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        while IFS= read -r rel_path; do
            [[ -n "${rel_path}" ]] || continue
            py_files+=("${SCRIPT_DIR}/${rel_path}")
        done < <(git -C "${SCRIPT_DIR}" ls-files '*.py')
    else
        while IFS= read -r -d '' f; do
            py_files+=("$f")
        done < <(find "${SCRIPT_DIR}" -name '*.py' \
            -not -path '*/.venv*' \
            -not -path '*/node_modules/*' \
            -not -path '*/spack_store/*' \
            -not -path '*/.spack-env/*' \
            -not -path '*/__pycache__/*' \
            -print0)
    fi

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

    section "Python: pytest"
    PYTEST="${VENV_DIR}/bin/pytest"
    if [[ -x "${PYTEST}" ]] && [[ ${#py_files[@]} -gt 0 ]]; then
        PYTEST_ARGS=(
            --ignore=pkg
            --ignore=outputs
            --ignore=llm_speculative_decoding_gpt2_test.py
            --ignore=tools/qwen3_scale_test.py
            -q
        )
        if "${PYTEST}" "${PYTEST_ARGS[@]}"; then
            log "PASS: pytest"
        else
            pytest_status=$?
            if [[ ${pytest_status} -eq 5 ]]; then
                log "SKIP: no host-safe Python tests collected"
            else
                log "FAIL: pytest"
                ((FAILURES++)) || true
            fi
        fi
    else
        log "SKIP: pytest not installed or no Python files"
    fi
else
    log "SKIP: Python lint venv not found at ${VENV_DIR}"
    log "  Create with: uv venv ${VENV_DIR} && uv pip install --python ${VENV_DIR}/bin/python ruff black pytest pytest-cov mypy"
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
        if git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            while IFS= read -r rel_path; do
                [[ -n "${rel_path}" ]] || continue
                shell_files+=("${SCRIPT_DIR}/${rel_path}")
            done < <(git -C "${SCRIPT_DIR}" ls-files '*.sh')
        else
            while IFS= read -r -d '' f; do
                shell_files+=("$f")
            done < <(find "${SCRIPT_DIR}" -name '*.sh' \
                -not -path '*/.venv*' \
                -not -path '*/node_modules/*' \
                -not -path '*/.spack-env/*' \
                -not -path '*/spack_store/*' \
                -print0)
        fi

        if [[ ${#shell_files[@]} -gt 0 ]]; then
            run_check "shellcheck" "${SHELLCHECK}" -s bash -S warning "${shell_files[@]}" \
                -e SC2034 # Ignore unused variable warnings for config constants
        fi
    else
        log "SKIP: shellcheck not found"
    fi
fi

# ---- Zephyr contract anti-drift checks ----
section "Zephyr: contract checks"
run_check "check_zephyr_contracts.sh" "${SCRIPT_DIR}/tools/check_zephyr_contracts.sh"

# ---- Infra checks ----
if [[ "${INFRA}" == "true" ]]; then
    section "Infra: verify_all"
    if [[ "${INFRA_FULL}" == "true" ]]; then
        run_check "verify_all (full)" ./container/verify_all.sh
    else
        run_check "verify_all (smoke)" ./container/verify_all.sh --smoke
    fi
fi

# ---- Multi-repo unit tests (no Docker/GPU needed) ----
if [[ "${MULTI_REPO_UNIT}" == "true" ]]; then
    section "Multi-repo: unit tests"
    run_check "launch_container_test.sh" bash "${SCRIPT_DIR}/container/launch_container_test.sh"
fi

# ---- Multi-repo integration + E2E tests (Docker + GPU) ----
if [[ "${MULTI_REPO}" == "true" ]]; then
    section "Multi-repo: integration (Docker, no GPU)"
    run_check "verify_multi_repo.sh" bash "${SCRIPT_DIR}/container/verify_multi_repo.sh"

    section "Multi-repo: E2E (Docker + GPU)"
    run_check "verify_multi_repo_e2e.sh" bash "${SCRIPT_DIR}/container/verify_multi_repo_e2e.sh"
fi

# ---- Snapshot image verification ----
if [[ "${SNAPSHOT}" == "true" ]]; then
    SNAPSHOT_FLAGS=()
    if [[ "${SNAPSHOT_NO_GPU}" == "true" ]]; then
        SNAPSHOT_FLAGS+=("--no-gpu")
    fi
    section "Snapshot image: verification"
    run_check "verify_snapshot.sh" bash "${SCRIPT_DIR}/container/verify_snapshot.sh" "${SNAPSHOT_FLAGS[@]}"
fi

# ---- UV-Spack layering verification ----
if [[ "${UV_LAYERING}" == "true" ]]; then
    UV_LAYERING_FLAGS=()
    if [[ "${UV_LAYERING_NO_GPU}" == "true" ]]; then
        UV_LAYERING_FLAGS+=("--no-gpu")
    fi
    section "UV-Spack layering: verification"
    run_check "verify_uv_layering.sh" bash "${SCRIPT_DIR}/container/verify_uv_layering.sh" "${UV_LAYERING_FLAGS[@]}"
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
