#!/bin/bash
#
# E2E Tests for Multi-Repo Container Skill
# =========================================
#
# Layer 3: Requires Docker, GPU, and the pre-built 42GB Spack store.
# These tests are slow and should only be run when validating GPU functionality.
#
# Verifies:
#   - Legacy backward compatibility (verify-spack entrypoint still passes)
#   - Multi-repo GPU validation (torch/jax work from external repo via shared store)
#   - Multi-repo default entrypoint (full Zephyr env activation with GPU)
#   - UV venv isolation across projects (different project IDs get different workspaces)
#   - Workspace persistence across container relaunches
#
# Usage:
#   bash container/verify_multi_repo_e2e.sh
#
# Prerequisites:
#   - Docker daemon with NVIDIA runtime
#   - GPU available
#   - sygaldry/zephyr:base image built
#   - Spack store with JAX + Torch installed at default location

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
source "${SCRIPT_DIR}/lib/verify_common.sh"

verify_reset_counters

# Unique project IDs per test run
TEST_PROJECT_LEGACY="e2e-legacy-$$"
TEST_PROJECT_MULTI="e2e-multi-$$"
TEST_PROJECT_A="e2e-proj-a-$$"
TEST_PROJECT_B="e2e-proj-b-$$"
TEST_PROJECT_PERSIST="e2e-persist-$$"

# Temp dirs
CLEANUP_DIRS=()
CLEANUP_PROJECTS=()
cleanup() {
    for d in "${CLEANUP_DIRS[@]}"; do
        rm -rf "${d}" 2>/dev/null || true
    done
    for p in "${CLEANUP_PROJECTS[@]}"; do
        rm -rf "/mnt/data_infra/zephyr_container_infra/${p}" 2>/dev/null || true
    done
}
trap cleanup EXIT

CLEANUP_PROJECTS+=(
    "${TEST_PROJECT_LEGACY}"
    "${TEST_PROJECT_MULTI}"
    "${TEST_PROJECT_A}"
    "${TEST_PROJECT_B}"
    "${TEST_PROJECT_PERSIST}"
)

# ============================================================================
# Preflight
# ============================================================================

echo "=== Preflight ==="

if ! verify_require_docker; then
    echo "ERROR: Docker not found. Skipping E2E tests." >&2
    exit 0
fi

IMAGE="${SYGALDRY_IMAGE:-sygaldry/zephyr:base}"
if ! verify_require_image "${IMAGE}"; then
    echo "ERROR: Image ${IMAGE} not found. Skipping E2E tests." >&2
    exit 0
fi

# Check GPU is available
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi not found. Skipping E2E tests (GPU required)." >&2
    exit 0
fi

if ! nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi failed. Skipping E2E tests (GPU required)." >&2
    exit 0
fi

echo "  Docker: OK"
echo "  Image: ${IMAGE}"
echo "  GPU: OK"

# ============================================================================
# Test 1: Legacy Backward Compatibility (verify-spack)
# ============================================================================

echo ""
echo "=== Legacy Backward Compatibility ==="
echo "  Running verify-spack.sh entrypoint (torch + jax + tensor ops + NN ops)..."

if SYGALDRY_PROJECT_ID="${TEST_PROJECT_LEGACY}" \
   SYGALDRY_BUILD_IMAGE=never \
   "${REPO_ROOT}/container/launch_container.sh" \
   --entrypoint verify-spack 2>&1 | tail -5; then
    pass "Legacy: verify-spack passes (torch + jax GPU validation)"
else
    fail "Legacy: verify-spack passes (torch + jax GPU validation)"
fi

# ============================================================================
# Test 2: Multi-Repo GPU Validation
# ============================================================================

echo ""
echo "=== Multi-Repo GPU Validation ==="

# Create a temp repo with a GPU test script
FAKE_REPO="$(mktemp -d)"
CLEANUP_DIRS+=("${FAKE_REPO}")

cat > "${FAKE_REPO}/test_gpu.py" << 'PYTEST'
import torch
assert torch.cuda.is_available(), "CUDA not available"
assert torch.cuda.device_count() > 0, "No CUDA devices"
import jax
gpu_devices = [d for d in jax.devices() if d.platform == "gpu"]
assert len(gpu_devices) > 0, f"No JAX GPU devices: {jax.devices()}"
print("MULTI_REPO_GPU_OK")
PYTEST

echo "  Running GPU test from external repo via shared Spack store..."

result="$(SYGALDRY_PROJECT_ID="${TEST_PROJECT_MULTI}" \
    SYGALDRY_BUILD_IMAGE=never \
    "${REPO_ROOT}/container/launch_container.sh" \
    --repo "${FAKE_REPO}" \
    --entrypoint run-job.sh -- \
    bash -c "source /opt/spack_src/share/spack/setup-env.sh && spack env activate \${SYGALDRY_ROOT}/pkg/zephyr && python \$(pwd)/test_gpu.py" 2>&1 | tail -5)" || true

if [[ "${result}" == *"MULTI_REPO_GPU_OK"* ]]; then
    pass "Multi-repo: torch + jax GPU validation via shared Spack store"
else
    fail "Multi-repo: torch + jax GPU validation via shared Spack store" "output: ${result}"
fi

# ============================================================================
# Test 3: Multi-Repo Default Entrypoint (full Zephyr activation)
# ============================================================================

echo ""
echo "=== Multi-Repo Default Entrypoint ==="
echo "  Running default entrypoint with gpu-test and jax-test aliases..."

FAKE_REPO2="$(mktemp -d)"
CLEANUP_DIRS+=("${FAKE_REPO2}")
echo "marker" > "${FAKE_REPO2}/MARKER"

# The default entrypoint activates the Zephyr env and does GPU validation,
# then runs the provided command. We test that gpu-test works.
# Note: aliases may not expand in non-interactive bash -c, so use the underlying commands.
result="$(SYGALDRY_PROJECT_ID="${TEST_PROJECT_MULTI}" \
    SYGALDRY_BUILD_IMAGE=never \
    "${REPO_ROOT}/container/launch_container.sh" \
    --repo "${FAKE_REPO2}" \
    --entrypoint default -- \
    bash -c 'python3 -c "import torch; print(f\"CUDA: {torch.cuda.is_available()}\")" && python3 -c "import jax; print(f\"Devices: {jax.devices()}\")"' 2>&1 | tail -5)" || true

if [[ "${result}" == *"CUDA: True"* ]]; then
    pass "Multi-repo: default entrypoint activates Zephyr env with GPU"
else
    fail "Multi-repo: default entrypoint activates Zephyr env with GPU" "output: ${result}"
fi

# ============================================================================
# Test 4: UV Venv Isolation Across Projects
# ============================================================================

echo ""
echo "=== UV Venv Isolation ==="

REPO_A="$(mktemp -d)"
REPO_B="$(mktemp -d)"
CLEANUP_DIRS+=("${REPO_A}" "${REPO_B}")

echo "  Creating marker in project A workspace..."
SYGALDRY_PROJECT_ID="${TEST_PROJECT_A}" \
SYGALDRY_BUILD_IMAGE=never \
    "${REPO_ROOT}/container/launch_container.sh" \
    --repo "${REPO_A}" \
    --entrypoint run-job.sh -- \
    bash -c 'echo "project-a-marker" > /workspace/isolation-test.txt' 2>/dev/null || true

echo "  Checking project B workspace does not see project A's files..."
result="$(SYGALDRY_PROJECT_ID="${TEST_PROJECT_B}" \
    SYGALDRY_BUILD_IMAGE=never \
    "${REPO_ROOT}/container/launch_container.sh" \
    --repo "${REPO_B}" \
    --entrypoint run-job.sh -- \
    bash -c 'test ! -f /workspace/isolation-test.txt && echo ISOLATED || echo LEAKED' 2>/dev/null)" || true

if [[ "${result}" == "ISOLATED" ]]; then
    pass "UV isolation: project B does not see project A's workspace files"
else
    fail "UV isolation: project B does not see project A's workspace files" "got '${result}'"
fi

# ============================================================================
# Test 5: Workspace Persistence Across Relaunches
# ============================================================================

echo ""
echo "=== Workspace Persistence ==="

REPO_PERSIST="$(mktemp -d)"
CLEANUP_DIRS+=("${REPO_PERSIST}")

echo "  Launch 1: writing persist marker..."
SYGALDRY_PROJECT_ID="${TEST_PROJECT_PERSIST}" \
SYGALDRY_BUILD_IMAGE=never \
    "${REPO_ROOT}/container/launch_container.sh" \
    --repo "${REPO_PERSIST}" \
    --entrypoint run-job.sh -- \
    bash -c 'echo "survived-relaunch" > /workspace/persist-marker.txt' 2>/dev/null || true

echo "  Launch 2: reading persist marker..."
result="$(SYGALDRY_PROJECT_ID="${TEST_PROJECT_PERSIST}" \
    SYGALDRY_BUILD_IMAGE=never \
    "${REPO_ROOT}/container/launch_container.sh" \
    --repo "${REPO_PERSIST}" \
    --entrypoint run-job.sh -- \
    bash -c 'cat /workspace/persist-marker.txt 2>/dev/null || echo MISSING' 2>/dev/null)" || true

if [[ "${result}" == "survived-relaunch" ]]; then
    pass "Persistence: workspace files survive container relaunch"
else
    fail "Persistence: workspace files survive container relaunch" "got '${result}'"
fi

# ============================================================================
# Summary
# ============================================================================

verify_print_summary "E2E Test Summary"
verify_exit_on_failures
