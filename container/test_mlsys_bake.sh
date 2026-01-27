#!/bin/bash
#
# Integration test for baked MLSys container images.
#
# Builds the smallest image (hf-transformers), then runs a progressive
# sequence of checks — from fast metadata queries up to full GPU functional
# tests — to verify the end-to-end flow.
#
# Usage:
#   ./container/test_mlsys_bake.sh          # full run (build + verify)
#   ./container/test_mlsys_bake.sh --skip-build  # verify only (image must exist)
#

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
export PROJECT_ROOT
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
readonly TEST_ENV="hf-transformers"          # smallest/fastest to build
readonly IMAGE="sygaldry/zephyr:hf"          # expected tag
readonly SPACK_IMAGE="sygaldry/zephyr:spack"

SKIP_BUILD=false
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=true

TESTS_RUN=0
TESTS_PASSED=0
FAILURES=0

pass() { ((TESTS_PASSED++)) || true; ((TESTS_RUN++)) || true; echo "  PASS: $1"; }
fail() { ((FAILURES++)) || true; ((TESTS_RUN++)) || true; echo "  FAIL: $1"; [[ -n "${2:-}" ]] && echo "        $2"; }

# ---------------------------------------------------------------------------
# Phase 0: Build
# ---------------------------------------------------------------------------

if [[ "${SKIP_BUILD}" == "true" ]]; then
    echo "=== Phase 0: Build (skipped) ==="
    echo ""
else
    echo "=== Phase 0: Build hf-transformers image ==="
    echo ""
    if ! bash "${SCRIPT_DIR}/snapshot_mlsys.sh" "${TEST_ENV}" --no-verify; then
        echo "FATAL: Build failed. Cannot continue."
        exit 1
    fi
    echo ""
fi

# Confirm image exists
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "FATAL: Image ${IMAGE} not found."
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 1: Image metadata (no container needed)
# ---------------------------------------------------------------------------

echo "=== Phase 1: Image Metadata ==="

label="$(docker inspect --format='{{index .Config.Labels "sygaldry.mlsys.baked"}}' "${IMAGE}" 2>/dev/null || echo "")"
[[ "${label}" == "true" ]] && pass "Label sygaldry.mlsys.baked=true" || fail "Label sygaldry.mlsys.baked" "got '${label}'"

label="$(docker inspect --format='{{index .Config.Labels "sygaldry.mlsys.env"}}' "${IMAGE}" 2>/dev/null || echo "")"
[[ "${label}" == "${TEST_ENV}" ]] && pass "Label sygaldry.mlsys.env=${TEST_ENV}" || fail "Label sygaldry.mlsys.env" "got '${label}'"

label="$(docker inspect --format='{{index .Config.Labels "sygaldry.spack.baked"}}' "${IMAGE}" 2>/dev/null || echo "")"
[[ "${label}" == "true" ]] && pass "Parent label sygaldry.spack.baked=true" || fail "Parent label" "got '${label}'"

env_val="$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${IMAGE}" | grep '^SYGALDRY_MLSYS_ENV=' | cut -d= -f2-)"
[[ "${env_val}" == "${TEST_ENV}" ]] && pass "ENV SYGALDRY_MLSYS_ENV=${TEST_ENV}" || fail "ENV SYGALDRY_MLSYS_ENV" "got '${env_val}'"

env_val="$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${IMAGE}" | grep '^SYGALDRY_MLSYS_VENV_ROOT=' | cut -d= -f2-)"
[[ "${env_val}" == "/opt/mlsys-envs" ]] && pass "ENV SYGALDRY_MLSYS_VENV_ROOT=/opt/mlsys-envs" || fail "ENV SYGALDRY_MLSYS_VENV_ROOT" "got '${env_val}'"

env_val="$(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "${IMAGE}" | grep '^SYGALDRY_SETUP_COMPLETE=' | cut -d= -f2-)"
[[ "${env_val}" == "1" ]] && pass "ENV SYGALDRY_SETUP_COMPLETE=1" || fail "ENV SYGALDRY_SETUP_COMPLETE" "got '${env_val}'"

# CMD should be empty (overridden from spack snapshot's ["bash","--login"])
cmd="$(docker inspect --format='{{json .Config.Cmd}}' "${IMAGE}" 2>/dev/null)"
if [[ "${cmd}" == "null" ]] || [[ "${cmd}" == "[]" ]]; then
    pass "CMD is empty (was [])"
else
    fail "CMD is empty" "got '${cmd}'"
fi

echo ""

# ---------------------------------------------------------------------------
# Phase 2: Filesystem structure (no GPU)
# ---------------------------------------------------------------------------

echo "=== Phase 2: Filesystem (no GPU container) ==="

run() { docker run --rm --entrypoint /bin/bash "${IMAGE}" -c "$1" 2>/dev/null; }

result="$(run 'test -d /opt/mlsys-envs && echo yes')" || true
[[ "${result}" == "yes" ]] && pass "Venv root /opt/mlsys-envs exists" || fail "Venv root exists"

result="$(run 'cat /opt/mlsys-envs/.default-env')" || true
[[ "${result}" == "${TEST_ENV}" ]] && pass ".default-env = ${TEST_ENV}" || fail ".default-env" "got '${result}'"

result="$(run 'cat /opt/mlsys-envs/.manifest')" || true
[[ -n "${result}" ]] && pass ".manifest present ($(echo "${result}" | wc -l | tr -d ' ') entries)" || fail ".manifest"

result="$(run 'test -f /opt/mlsys-envs/hf-transformers/bin/activate && echo yes')" || true
[[ "${result}" == "yes" ]] && pass "bin/activate exists at /opt/mlsys-envs/hf-transformers/" || fail "bin/activate missing"

result="$(run 'test -f /opt/mlsys-envs/hf-transformers/bin/python3 && echo yes')" || true
[[ "${result}" == "yes" ]] && pass "bin/python3 exists in venv" || fail "bin/python3 missing"

result="$(run 'test -x /opt/sygaldry/skills/zephyr-mlsys-env/scripts/uv-env-build.sh && echo yes')" || true
[[ "${result}" == "yes" ]] && pass "MLSys skill scripts baked" || fail "MLSys skill scripts missing"

# Updated entrypoints contain auto-activation code
result="$(run 'grep -c _activate_baked_mlsys_venv /opt/container_entrypoints/default.sh')" || true
if [[ -n "${result}" ]] && [[ "${result}" -gt 0 ]] 2>/dev/null; then
    pass "default.sh has auto-activation code"
else
    fail "default.sh auto-activation code" "grep count: '${result}'"
fi

result="$(run 'grep -c SYGALDRY_MLSYS_ENV /opt/container_entrypoints/run-job.sh')" || true
if [[ -n "${result}" ]] && [[ "${result}" -gt 0 ]] 2>/dev/null; then
    pass "run-job.sh has auto-activation code"
else
    fail "run-job.sh auto-activation code" "grep count: '${result}'"
fi

# .bashrc has the mlsys snippet
result="$(run 'grep -c mlsys-activate /home/kvothe/.bashrc')" || true
if [[ -n "${result}" ]] && [[ "${result}" -gt 0 ]] 2>/dev/null; then
    pass ".bashrc has mlsys-activate function"
else
    fail ".bashrc mlsys-activate" "grep count: '${result}'"
fi

echo ""

# ---------------------------------------------------------------------------
# Phase 3: Python imports (no GPU, via venv python)
# ---------------------------------------------------------------------------

echo "=== Phase 3: Python Imports (no GPU) ==="

venv_py="/opt/mlsys-envs/hf-transformers/bin/python3"

for mod in transformers tokenizers accelerate; do
    result="$(run "${venv_py} -c 'import ${mod}; print(${mod}.__version__)'" 2>/dev/null)" || true
    if [[ -n "${result}" ]] && [[ "${result}" != *"Error"* ]]; then
        pass "import ${mod} (${result})"
    else
        fail "import ${mod}" "got '${result}'"
    fi
done

# Spack packages should still be visible through the venv
for mod in torch numpy scipy; do
    result="$(run "${venv_py} -c 'import ${mod}; print(${mod}.__version__)'" 2>/dev/null)" || true
    if [[ -n "${result}" ]] && [[ "${result}" != *"Error"* ]]; then
        pass "Spack: import ${mod} (${result})"
    else
        fail "Spack: import ${mod}" "got '${result}'"
    fi
done

echo ""

# ---------------------------------------------------------------------------
# Phase 4: Entrypoint auto-activation
# ---------------------------------------------------------------------------
# default.sh and run-job.sh perform GPU validation (errors go to stderr,
# script continues without set -e).  We suppress stderr and grep for the
# specific output lines we care about.

echo "=== Phase 4: Entrypoint Auto-Activation ==="

# Test: default.sh with a command (exec path) exports VIRTUAL_ENV
result="$(docker run --rm "${IMAGE}" bash -c 'echo "VIRTUAL_ENV=${VIRTUAL_ENV:-unset}"' 2>/dev/null \
    | grep '^VIRTUAL_ENV=')" || true
if [[ "${result}" == VIRTUAL_ENV=/opt/mlsys-envs/* ]]; then
    pass "default.sh exec path: ${result}"
else
    fail "default.sh exec path: VIRTUAL_ENV" "got '${result}'"
fi

# Test: run-job.sh exports VIRTUAL_ENV
result="$(docker run --rm --entrypoint /opt/container_entrypoints/run-job.sh "${IMAGE}" \
    bash -c 'echo "VIRTUAL_ENV=${VIRTUAL_ENV:-unset}"' 2>/dev/null \
    | grep '^VIRTUAL_ENV=')" || true
if [[ "${result}" == VIRTUAL_ENV=/opt/mlsys-envs/* ]]; then
    pass "run-job.sh: ${result}"
else
    fail "run-job.sh: VIRTUAL_ENV" "got '${result}'"
fi

# Test: .bashrc activation (bypass entrypoint entirely — only bashrc matters)
result="$(docker run --rm --entrypoint /bin/bash "${IMAGE}" -ic \
    'echo "VIRTUAL_ENV=${VIRTUAL_ENV:-unset}"' 2>/dev/null \
    | grep '^VIRTUAL_ENV=')" || true
if [[ "${result}" == VIRTUAL_ENV=/opt/mlsys-envs/* ]]; then
    pass "bashrc path (entrypoint bypassed): ${result}"
else
    fail "bashrc activation (entrypoint bypassed)" "got '${result}'"
fi

# Test: python resolves to venv python through default entrypoint
result="$(docker run --rm "${IMAGE}" \
    python3 -c 'import sys; print(sys.executable)' 2>/dev/null | tail -1)" || true
if [[ "${result}" == /opt/mlsys-envs/* ]]; then
    pass "python3 resolves to venv: ${result}"
else
    fail "python3 resolves to venv" "got '${result}'"
fi

# Test: import transformers works end-to-end through default entrypoint
result="$(docker run --rm "${IMAGE}" \
    python3 -c 'import transformers; print(f"transformers {transformers.__version__}")' 2>/dev/null | tail -1)" || true
if [[ "${result}" == transformers* ]]; then
    pass "default entrypoint: ${result}"
else
    fail "default entrypoint: import transformers" "got '${result}'"
fi

echo ""

# ---------------------------------------------------------------------------
# Phase 5: GPU functional (requires NVIDIA runtime)
# ---------------------------------------------------------------------------

echo "=== Phase 5: GPU Functional ==="

if ! docker info 2>/dev/null | grep -q nvidia; then
    echo "  SKIP: NVIDIA Docker runtime not detected"
else
    # torch CUDA through the venv
    result="$(docker run --rm --runtime=nvidia --gpus=all "${IMAGE}" \
        python3 -c 'import torch; print(torch.cuda.is_available())' 2>/dev/null | tail -1)" || true
    [[ "${result}" == "True" ]] && pass "torch.cuda.is_available() via venv" || fail "torch CUDA" "got '${result}'"

    # GPU matmul
    result="$(docker run --rm --runtime=nvidia --gpus=all "${IMAGE}" \
        python3 -c '
import torch
a = torch.randn(64, 64, device="cuda")
b = torch.randn(64, 64, device="cuda")
c = torch.matmul(a, b)
assert c.shape == (64, 64)
print("OK")
' 2>/dev/null | tail -1)" || true
    [[ "${result}" == "OK" ]] && pass "GPU matmul" || fail "GPU matmul" "got '${result}'"

    # JAX GPU
    result="$(docker run --rm --runtime=nvidia --gpus=all "${IMAGE}" \
        python3 -c 'import jax; devs=[d for d in jax.devices() if d.platform=="gpu"]; print(len(devs))' 2>/dev/null | tail -1)" || true
    if [[ -n "${result}" ]] && [[ "${result}" -gt 0 ]] 2>/dev/null; then
        pass "JAX sees ${result} GPU device(s)"
    else
        fail "JAX GPU" "got '${result}'"
    fi

    # Full auto-activation: default entrypoint, check VIRTUAL_ENV + import
    result="$(docker run --rm --runtime=nvidia --gpus=all "${IMAGE}" \
        bash -c 'echo "VIRTUAL_ENV=${VIRTUAL_ENV:-unset}"; python3 -c "import transformers; print(transformers.__version__)"' 2>/dev/null \
        | grep '^VIRTUAL_ENV=')" || true
    if [[ "${result}" == VIRTUAL_ENV=/opt/mlsys-envs/* ]]; then
        pass "Full auto-activation with GPU: ${result}"
    else
        fail "Full auto-activation with GPU" "got '${result}'"
    fi
fi

echo ""

# ---------------------------------------------------------------------------
# Phase 6: Image size sanity
# ---------------------------------------------------------------------------

echo "=== Phase 6: Image Size ==="

spack_size="$(docker image inspect "${SPACK_IMAGE}" --format='{{.Size}}' 2>/dev/null || echo "0")"
mlsys_size="$(docker image inspect "${IMAGE}" --format='{{.Size}}' 2>/dev/null || echo "0")"
delta="$(( (mlsys_size - spack_size) / 1048576 ))"  # in MB

spack_gb="$(echo "scale=1; ${spack_size} / 1073741824" | bc)"
mlsys_gb="$(echo "scale=1; ${mlsys_size} / 1073741824" | bc)"

echo "  Spack snapshot: ${spack_gb} GB"
echo "  MLSys image:    ${mlsys_gb} GB"
echo "  Delta:          ${delta} MB"

# hf-transformers should add < 2 GB
if [[ ${delta} -gt 0 ]] && [[ ${delta} -lt 2048 ]]; then
    pass "Size delta ${delta} MB (expected < 2048 MB for hf-transformers)"
else
    fail "Size delta ${delta} MB outside expected range (0..2048)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "========================================"
echo " MLSys Bake Test Summary"
echo "========================================"
echo " Image:   ${IMAGE}"
echo " Env:     ${TEST_ENV}"
echo " Tests:   ${TESTS_RUN}"
echo " Passed:  ${TESTS_PASSED}"
echo " Failed:  ${FAILURES}"
echo "========================================"

if [[ ${FAILURES} -ne 0 ]]; then
    exit 1
fi
