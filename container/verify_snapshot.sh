#!/bin/bash
#
# Snapshot Image Verification
# ============================
#
# Validates that a Spack snapshot image (sygaldry.spack.baked=true) is
# self-contained and functional.  Can verify both locally-built and
# registry-pulled images.
#
# Usage:
#   ./container/verify_snapshot.sh                                    # default image
#   ./container/verify_snapshot.sh ghcr.io/phi9t/sygaldry/zephyr:spack  # specific image
#   ./container/verify_snapshot.sh --no-gpu                           # skip GPU tests (T1-T4 only)
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#
# Prerequisites:
#   - Docker daemon running
#   - For GPU tests (T5-T7): NVIDIA Docker runtime + GPU

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
source "${SCRIPT_DIR}/lib/verify_common.sh"

# ============================================================================
# Configuration
# ============================================================================

IMAGE="${SYGALDRY_SNAPSHOT_IMAGE:-sygaldry/zephyr:spack}"
GPU=true

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-gpu)
            GPU=false
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [IMAGE] [--no-gpu]"
            echo ""
            echo "Verify a Spack snapshot image is self-contained and functional."
            echo ""
            echo "Options:"
            echo "  IMAGE       Docker image to test (default: sygaldry/zephyr:spack)"
            echo "  --no-gpu    Skip GPU tests (T5-T7); only run metadata/structure/import tests"
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

readonly IMAGE
readonly GPU

verify_reset_counters

# Run a command inside the snapshot image (no GPU, no host mounts for spack)
run_no_gpu() {
    local cmd="$1"
    verify_run_no_gpu "${IMAGE}" "${cmd}" 2>/dev/null
}

# Run a command inside the snapshot image with GPU
run_with_gpu() {
    local cmd="$1"
    verify_run_with_gpu "${IMAGE}" "${cmd}" 2>/dev/null
}

# ============================================================================
# Preflight
# ============================================================================

echo "=== Snapshot Image Verification ==="
echo ""
echo "  Image: ${IMAGE}"
echo "  GPU tests: ${GPU}"
echo ""

verify_require_docker || exit 1
verify_require_image "${IMAGE}" || exit 1
echo "  Docker: OK"
echo "  Image found: $(verify_image_size_gb "${IMAGE}")"
echo ""

# ============================================================================
# T1: Image Metadata
# ============================================================================

echo "=== T1: Image Metadata ==="

# Label: sygaldry.spack.baked=true
baked_label="$(docker inspect --format='{{index .Config.Labels "sygaldry.spack.baked"}}' "${IMAGE}" 2>/dev/null || echo "")"
if [[ "${baked_label}" == "true" ]]; then
    pass "Label sygaldry.spack.baked=true"
else
    fail "Label sygaldry.spack.baked=true" "got '${baked_label}'"
fi

# ENV: SYGALDRY_SPACK_ENV
spack_env_val="$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${IMAGE}" 2>/dev/null | grep '^SYGALDRY_SPACK_ENV=' | head -1 | cut -d= -f2-)"
if [[ "${spack_env_val}" == "/opt/spack_env/default" ]]; then
    pass "ENV SYGALDRY_SPACK_ENV=/opt/spack_env/default"
else
    fail "ENV SYGALDRY_SPACK_ENV=/opt/spack_env/default" "got '${spack_env_val}'"
fi

# ENV: SYGALDRY_IN_CONTAINER
in_container_val="$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${IMAGE}" 2>/dev/null | grep '^SYGALDRY_IN_CONTAINER=' | head -1 | cut -d= -f2-)"
if [[ "${in_container_val}" == "1" ]]; then
    pass "ENV SYGALDRY_IN_CONTAINER=1"
else
    fail "ENV SYGALDRY_IN_CONTAINER=1" "got '${in_container_val}'"
fi

# ============================================================================
# T2: Filesystem Structure (no GPU)
# ============================================================================

echo ""
echo "=== T2: Filesystem Structure ==="

# View symlink resolves
result="$(run_no_gpu 'test -L /opt/spack_store/view && readlink /opt/spack_store/view')" || true
if [[ "${result}" == /opt/spack_store/* ]]; then
    pass "View symlink resolves to /opt/spack_store/..."
else
    fail "View symlink resolves" "got '${result}'"
fi

# View target directory exists and has content
result="$(run_no_gpu 'test -d /opt/spack_store/view/bin && echo yes')" || true
if [[ "${result}" == "yes" ]]; then
    pass "View directory /opt/spack_store/view/bin exists"
else
    fail "View directory /opt/spack_store/view/bin exists"
fi

# spack.yaml in baked env
result="$(run_no_gpu 'test -f /opt/spack_env/default/spack.yaml && echo yes')" || true
if [[ "${result}" == "yes" ]]; then
    pass "Baked env: spack.yaml exists"
else
    fail "Baked env: spack.yaml exists"
fi

# spack.lock in baked env
result="$(run_no_gpu 'test -f /opt/spack_env/default/spack.lock && echo yes')" || true
if [[ "${result}" == "yes" ]]; then
    pass "Baked env: spack.lock exists"
else
    fail "Baked env: spack.lock exists"
fi

# Entrypoints present and executable
for ep in default.sh run-job.sh verify-gpu.sh verify-spack.sh spack-build.sh; do
    result="$(run_no_gpu "test -x /opt/container_entrypoints/${ep} && echo yes")" || true
    if [[ "${result}" == "yes" ]]; then
        pass "Entrypoint ${ep} present and executable"
    else
        fail "Entrypoint ${ep} present and executable"
    fi
done

# install_tree/.spack-db exists
result="$(run_no_gpu 'test -d /opt/spack_store/install_tree/.spack-db && echo yes')" || true
if [[ "${result}" == "yes" ]]; then
    pass "install_tree/.spack-db exists"
else
    fail "install_tree/.spack-db exists"
fi

# ============================================================================
# T3: Python Imports (no GPU)
# ============================================================================

echo ""
echo "=== T3: Python Imports ==="

for mod in torch jax numpy scipy; do
    result="$(run_no_gpu "/opt/spack_store/view/bin/python3 -c 'import ${mod}; print(${mod}.__version__)'" 2>/dev/null)" || true
    if [[ -n "${result}" ]] && [[ "${result}" != *"Error"* ]] && [[ "${result}" != *"error"* ]]; then
        pass "import ${mod} (version: ${result})"
    else
        fail "import ${mod}" "got '${result}'"
    fi
done

# ============================================================================
# T4: Spack Env Activation (no GPU)
# ============================================================================

echo ""
echo "=== T4: Spack Env Activation ==="

# spack env activate succeeds
result="$(run_no_gpu '
    source /opt/spack_src/share/spack/setup-env.sh
    spack env activate /opt/spack_env/default
    echo "SPACK_ENV=${SPACK_ENV:-unset}"
')" || true
if [[ "${result}" == *"SPACK_ENV=/opt/spack_env/default"* ]]; then
    pass "spack env activate /opt/spack_env/default"
else
    fail "spack env activate /opt/spack_env/default" "got '${result}'"
fi

# spack find shows installed packages (at least py-torch)
result="$(run_no_gpu '
    source /opt/spack_src/share/spack/setup-env.sh
    spack env activate /opt/spack_env/default
    spack find 2>&1 | grep -c "\\[+\\]"
')" || true
if [[ -n "${result}" ]] && [[ "${result}" -gt 0 ]] 2>/dev/null; then
    pass "spack find shows ${result} installed packages"
else
    fail "spack find shows installed packages" "got '${result}'"
fi

# ============================================================================
# T7: No spack_store Shadowing (no GPU, no host mount)
# ============================================================================

echo ""
echo "=== T7: No spack_store Shadowing ==="

# /opt/spack_store is NOT empty (baked content visible without host mount)
result="$(run_no_gpu 'ls /opt/spack_store/install_tree/ | head -3 | wc -l')" || true
if [[ -n "${result}" ]] && [[ "${result}" -gt 0 ]] 2>/dev/null; then
    pass "Baked /opt/spack_store/install_tree is not empty (${result} entries)"
else
    fail "Baked /opt/spack_store/install_tree is not empty" "got '${result}'"
fi

# view/bin/python3 exists (accessible without mount)
result="$(run_no_gpu 'test -x /opt/spack_store/view/bin/python3 && echo yes')" || true
if [[ "${result}" == "yes" ]]; then
    pass "Baked view/bin/python3 accessible without host mount"
else
    fail "Baked view/bin/python3 accessible without host mount"
fi

# ============================================================================
# GPU Tests (T5-T6) -- skipped with --no-gpu
# ============================================================================

if [[ "${GPU}" != "true" ]]; then
    echo ""
    echo "=== GPU tests skipped (--no-gpu) ==="
else

    # Check NVIDIA runtime is available
    if ! verify_has_nvidia_runtime; then
        echo ""
        echo "=== GPU tests skipped (NVIDIA runtime not detected) ==="
    else

        # ====================================================================
        # T5: GPU Validation
        # ====================================================================

        echo ""
        echo "=== T5: GPU Validation ==="

        # torch.cuda.is_available()
        result="$(run_with_gpu '
            source /opt/spack_src/share/spack/setup-env.sh
            spack env activate /opt/spack_env/default 2>/dev/null
            python3 -c "import torch; print(torch.cuda.is_available())"
        ')" || true
        if [[ "${result}" == "True" ]]; then
            pass "torch.cuda.is_available() == True"
        else
            fail "torch.cuda.is_available()" "got '${result}'"
        fi

        # JAX GPU devices
        result="$(run_with_gpu '
            source /opt/spack_src/share/spack/setup-env.sh
            spack env activate /opt/spack_env/default 2>/dev/null
            python3 -c "import jax; devs=[d for d in jax.devices() if d.platform==\"gpu\"]; print(len(devs))"
        ')" || true
        if [[ -n "${result}" ]] && [[ "${result}" -gt 0 ]] 2>/dev/null; then
            pass "JAX sees ${result} GPU device(s)"
        else
            fail "JAX GPU devices" "got '${result}'"
        fi

        # Tensor matmul on GPU
        result="$(run_with_gpu '
            source /opt/spack_src/share/spack/setup-env.sh
            spack env activate /opt/spack_env/default 2>/dev/null
            python3 -c "
import torch
a = torch.randn(64, 64, device=\"cuda\")
b = torch.randn(64, 64, device=\"cuda\")
c = torch.matmul(a, b)
assert c.shape == (64, 64)
print(\"OK\")
"
        ')" || true
        if [[ "${result}" == "OK" ]]; then
            pass "Tensor matmul on GPU"
        else
            fail "Tensor matmul on GPU" "got '${result}'"
        fi

        # ====================================================================
        # T6: Launcher Integration
        # ====================================================================

        echo ""
        echo "=== T6: Launcher Integration ==="

        # Launcher with baked image: skips spack mount, uses baked entrypoints
        result="$(
            SYGALDRY_IMAGE="${IMAGE}" \
            SYGALDRY_BUILD_IMAGE=never \
                "${REPO_ROOT}/container/launch_container.sh" \
                --entrypoint run-job -- \
                python3 -c "import torch; assert torch.cuda.is_available(); print('OK')" \
            2>/dev/null
        )" || true
        if [[ "${result}" == "OK" ]]; then
            pass "Launcher + baked image: torch GPU OK"
        else
            fail "Launcher + baked image: torch GPU" "got '${result}'"
        fi

        # Launcher log should show "baked into image" for spack
        launcher_log="$(
            SYGALDRY_IMAGE="${IMAGE}" \
            SYGALDRY_BUILD_IMAGE=never \
                "${REPO_ROOT}/container/launch_container.sh" \
                --entrypoint run-job -- \
                echo "done" \
            2>&1
        )" || true
        if echo "${launcher_log}" | grep -q "baked into image"; then
            pass "Launcher log shows 'Spack: (baked into image)'"
        else
            fail "Launcher log shows 'Spack: (baked into image)'"
        fi

        # Launcher uses baked entrypoints path
        if echo "${launcher_log}" | grep -q "/opt/container_entrypoints/"; then
            pass "Launcher uses baked entrypoint path"
        else
            fail "Launcher uses baked entrypoint path"
        fi

    fi  # nvidia runtime check
fi  # GPU flag

# ============================================================================
# Summary
# ============================================================================

verify_print_summary "Snapshot Verification Summary" "${IMAGE}"
verify_exit_on_failures
