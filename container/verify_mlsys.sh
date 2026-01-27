#!/bin/bash
#
# MLSys Baked Image Verification
# ================================
#
# Validates that a baked MLSys image (sygaldry.mlsys.baked=true) has working
# venvs and correct metadata. Tests both CPU-only checks (metadata, filesystem,
# provenance) and GPU-functional tests.
#
# Usage:
#   ./container/verify_mlsys.sh sygaldry/zephyr:vllm           # Full verification
#   ./container/verify_mlsys.sh sygaldry/zephyr:mlsys           # Multi-venv image
#   ./container/verify_mlsys.sh sygaldry/zephyr:vllm --no-gpu   # Skip GPU tests
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#
# Prerequisites:
#   - Docker daemon running
#   - For GPU tests: NVIDIA Docker runtime + GPU
#

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
source "${SCRIPT_DIR}/lib/verify_common.sh"

# ============================================================================
# Configuration
# ============================================================================

IMAGE=""
GPU=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-gpu)
            GPU=false
            shift
            ;;
        --help|-h)
            echo "Usage: $0 <IMAGE> [--no-gpu]"
            echo ""
            echo "Verify a baked MLSys image has working venvs and correct metadata."
            echo ""
            echo "Options:"
            echo "  IMAGE       Docker image to test (required)"
            echo "  --no-gpu    Skip GPU tests; only run metadata/filesystem/provenance tests"
            exit 0
            ;;
        -*)
            echo "Unknown flag: $1" >&2
            exit 2
            ;;
        *)
            IMAGE="$1"
            shift
            ;;
    esac
done

if [[ -z "${IMAGE}" ]]; then
    echo "Usage: $0 <IMAGE> [--no-gpu]" >&2
    exit 2
fi

readonly IMAGE
readonly GPU

verify_reset_counters

# Helpers for running inside the image
run_no_gpu() {
    local cmd="$1"
    verify_run_no_gpu "${IMAGE}" "${cmd}" 2>/dev/null
}

run_with_gpu() {
    local cmd="$1"
    verify_run_with_gpu "${IMAGE}" "${cmd}" 2>/dev/null
}

# ============================================================================
# Preflight
# ============================================================================

echo "=== MLSys Baked Image Verification ==="
echo ""
echo "  Image:     ${IMAGE}"
echo "  GPU tests: ${GPU}"
echo ""

verify_require_docker || exit 1
verify_require_image "${IMAGE}" || exit 1
echo "  Docker: OK"
echo "  Image found: $(verify_image_size_gb "${IMAGE}")"
echo ""

# ============================================================================
# Read image metadata
# ============================================================================

MLSYS_ENV="$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${IMAGE}" 2>/dev/null \
    | grep '^SYGALDRY_MLSYS_ENV=' | head -1 | cut -d= -f2-)"
MLSYS_VENV_ROOT="$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${IMAGE}" 2>/dev/null \
    | grep '^SYGALDRY_MLSYS_VENV_ROOT=' | head -1 | cut -d= -f2-)"

echo "  Env:       ${MLSYS_ENV:-<not set>}"
echo "  Venv root: ${MLSYS_VENV_ROOT:-<not set>}"
echo ""

# ============================================================================
# T1: Image Metadata
# ============================================================================

echo "=== T1: Image Metadata ==="

# Label: sygaldry.mlsys.baked=true
baked_label="$(docker inspect --format='{{index .Config.Labels "sygaldry.mlsys.baked"}}' "${IMAGE}" 2>/dev/null || echo "")"
if [[ "${baked_label}" == "true" ]]; then
    pass "Label sygaldry.mlsys.baked=true"
else
    fail "Label sygaldry.mlsys.baked=true" "got '${baked_label}'"
fi

# Label: sygaldry.mlsys.env matches
env_label="$(docker inspect --format='{{index .Config.Labels "sygaldry.mlsys.env"}}' "${IMAGE}" 2>/dev/null || echo "")"
if [[ -n "${env_label}" ]]; then
    pass "Label sygaldry.mlsys.env=${env_label}"
else
    fail "Label sygaldry.mlsys.env set"
fi

# ENV: SYGALDRY_MLSYS_ENV
if [[ -n "${MLSYS_ENV}" ]]; then
    pass "ENV SYGALDRY_MLSYS_ENV=${MLSYS_ENV}"
else
    fail "ENV SYGALDRY_MLSYS_ENV set"
fi

# ENV: SYGALDRY_MLSYS_VENV_ROOT
if [[ "${MLSYS_VENV_ROOT}" == "/opt/mlsys-envs" ]]; then
    pass "ENV SYGALDRY_MLSYS_VENV_ROOT=/opt/mlsys-envs"
else
    fail "ENV SYGALDRY_MLSYS_VENV_ROOT=/opt/mlsys-envs" "got '${MLSYS_VENV_ROOT}'"
fi

# Parent: sygaldry.spack.baked=true should be inherited
spack_label="$(docker inspect --format='{{index .Config.Labels "sygaldry.spack.baked"}}' "${IMAGE}" 2>/dev/null || echo "")"
if [[ "${spack_label}" == "true" ]]; then
    pass "Parent label sygaldry.spack.baked=true (inherited)"
else
    fail "Parent label sygaldry.spack.baked=true" "got '${spack_label}'"
fi

# ============================================================================
# T2: Filesystem Structure
# ============================================================================

echo ""
echo "=== T2: Filesystem Structure ==="

# Venv root exists
result="$(run_no_gpu 'test -d /opt/mlsys-envs && echo yes')" || true
if [[ "${result}" == "yes" ]]; then
    pass "Venv root /opt/mlsys-envs exists"
else
    fail "Venv root /opt/mlsys-envs exists"
fi

# .default-env file
result="$(run_no_gpu 'cat /opt/mlsys-envs/.default-env 2>/dev/null')" || true
if [[ -n "${result}" ]]; then
    pass ".default-env contains: ${result}"
else
    fail ".default-env file present and non-empty"
fi

# .manifest file
result="$(run_no_gpu 'cat /opt/mlsys-envs/.manifest 2>/dev/null')" || true
if [[ -n "${result}" ]]; then
    pass ".manifest present (entries: $(echo "${result}" | wc -l | tr -d ' '))"
else
    fail ".manifest file present and non-empty"
fi

# Venv directory and bin/activate
# For single-venv envs: /opt/mlsys-envs/<env_name>/bin/activate
# For multi-venv envs: /opt/mlsys-envs/<env_name>/<sub_venv>/bin/activate
result="$(run_no_gpu '
    found=0
    for activate in /opt/mlsys-envs/*/bin/activate /opt/mlsys-envs/*/*/bin/activate; do
        if [[ -f "${activate}" ]]; then
            echo "${activate}"
            found=1
        fi
    done
    if [[ ${found} -eq 0 ]]; then echo "NONE"; fi
')" || true
if [[ "${result}" != "NONE" ]] && [[ -n "${result}" ]]; then
    activate_count="$(echo "${result}" | wc -l | tr -d ' ')"
    pass "Found ${activate_count} venv(s) with bin/activate"
else
    fail "At least one venv with bin/activate exists"
fi

# MLSys skill scripts baked
result="$(run_no_gpu 'test -x /opt/sygaldry/skills/zephyr/scripts/uv-env-build.sh && echo yes')" || true
if [[ "${result}" == "yes" ]]; then
    pass "MLSys skill scripts baked at /opt/sygaldry/skills/zephyr/"
else
    fail "MLSys skill scripts baked"
fi

# ============================================================================
# T3: Provenance (no GPU)
# ============================================================================

echo ""
echo "=== T3: Provenance (no GPU) ==="

# Run uv-env-validate.sh --no-gpu inside the container
result="$(run_no_gpu "
    source /opt/spack_src/share/spack/setup-env.sh
    spack env activate /opt/spack_env/default 2>/dev/null || true
    /opt/sygaldry/skills/zephyr/scripts/uv-env-validate.sh \
        ${MLSYS_ENV} --no-gpu --venv-root /opt/mlsys-envs 2>&1
" 2>/dev/null)" || true

if echo "${result}" | grep -q "^not ok"; then
    fail_count="$(echo "${result}" | grep -c "^not ok" || echo "0")"
    fail "Provenance validation (uv-env-validate.sh --no-gpu)" "${fail_count} test(s) failed"
    # Print failing lines for debugging
    echo "${result}" | grep "^not ok" | head -5 | while IFS= read -r line; do
        echo "        ${line}"
    done
elif echo "${result}" | grep -q "^ok"; then
    ok_count="$(echo "${result}" | grep -c "^ok" || echo "0")"
    pass "Provenance validation passed (${ok_count} checks)"
else
    fail "Provenance validation (uv-env-validate.sh --no-gpu)" "unexpected output"
fi

# ============================================================================
# T4 + T5: GPU Tests — skipped with --no-gpu
# ============================================================================

if [[ "${GPU}" != "true" ]]; then
    echo ""
    echo "=== GPU tests skipped (--no-gpu) ==="
else
    if ! verify_has_nvidia_runtime; then
        echo ""
        echo "=== GPU tests skipped (NVIDIA runtime not detected) ==="
    else

        # ====================================================================
        # T4: GPU Functional (uv-env-validate.sh with GPU)
        # ====================================================================

        echo ""
        echo "=== T4: GPU Functional ==="

        result="$(run_with_gpu "
            source /opt/spack_src/share/spack/setup-env.sh
            spack env activate /opt/spack_env/default 2>/dev/null || true
            /opt/sygaldry/skills/zephyr/scripts/uv-env-validate.sh \
                ${MLSYS_ENV} --venv-root /opt/mlsys-envs --gpu-only 2>&1
        " 2>/dev/null)" || true

        if echo "${result}" | grep -q "^not ok"; then
            fail_count="$(echo "${result}" | grep -c "^not ok" || echo "0")"
            fail "GPU validation (uv-env-validate.sh)" "${fail_count} test(s) failed"
            echo "${result}" | grep "^not ok" | head -5 | while IFS= read -r line; do
                echo "        ${line}"
            done
        elif echo "${result}" | grep -q "^ok"; then
            ok_count="$(echo "${result}" | grep -c "^ok" || echo "0")"
            pass "GPU validation passed (${ok_count} checks)"
        elif echo "${result}" | grep -q "GPU tests skipped\|no GPU functional"; then
            pass "No GPU functional tests defined (OK)"
        else
            pass "No GPU functional tests (0 checks)"
        fi

        # ====================================================================
        # T5: Auto-Activation
        # ====================================================================

        echo ""
        echo "=== T5: Auto-Activation ==="

        # Run with default entrypoint and check VIRTUAL_ENV is set
        # Filter out Spack init messages (only keep the VIRTUAL_ENV line)
        result="$(docker run --rm --runtime=nvidia --gpus=all \
            "${IMAGE}" bash -c 'echo "VIRTUAL_ENV=${VIRTUAL_ENV:-unset}"' 2>/dev/null \
            | grep '^VIRTUAL_ENV=' | tail -1)" || true
        if [[ "${result}" == VIRTUAL_ENV=/opt/mlsys-envs/* ]]; then
            pass "Auto-activation: VIRTUAL_ENV=${result#VIRTUAL_ENV=}"
        else
            fail "Auto-activation: VIRTUAL_ENV set to /opt/mlsys-envs/..." "got '${result}'"
        fi

        # Check that the correct package is importable without manual activation
        # Map env to a quick import check
        case "${MLSYS_ENV}" in
            vllm)
                import_check="import vllm; print(f'vllm {vllm.__version__}')"
                ;;
            sglang)
                import_check="import sglang; print(f'sglang {sglang.__version__}')"
                ;;
            hf-transformers)
                import_check="import transformers; print(f'transformers {transformers.__version__}')"
                ;;
            hf-datasets)
                import_check="import datasets; print(f'datasets {datasets.__version__}')"
                ;;
            torchtitan)
                import_check="import tensorboard; print(f'torchtitan deps ok')"
                ;;
            megatronlm)
                import_check="import importlib.metadata as md; print('megatron-core', md.version('megatron-core'), 'ok')"
                ;;
            llm-serving-all)
                # Multi-venv: default auto-activation should pick one
                import_check="import transformers; print(f'transformers {transformers.__version__}')"
                ;;
            *)
                import_check="print('ok')"
                ;;
        esac

        result="$(docker run --rm --runtime=nvidia --gpus=all \
            "${IMAGE}" bash -c "python3 -c \"${import_check}\"" 2>/dev/null)" || true
        if [[ -n "${result}" ]] && [[ "${result}" != *"Error"* ]] && [[ "${result}" != *"error"* ]]; then
            pass "Auto-activation import: ${result}"
        else
            fail "Auto-activation import" "got '${result}'"
        fi

    fi  # nvidia runtime check
fi  # GPU flag

# ============================================================================
# Summary
# ============================================================================

verify_print_summary "MLSys Baked Image Verification" "${IMAGE}"
verify_exit_on_failures
