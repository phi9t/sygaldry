#!/bin/bash
#
# Integration Tests for Multi-Repo Container Skill
# =================================================
#
# Layer 2: Requires Docker and the sygaldry/zephyr:base image.
# Does NOT require GPU -- tests use run-job.sh with lightweight bash commands.
#
# Verifies:
#   - Legacy mode mount layout and env vars
#   - Multi-repo mode mount layout, env vars, and workdir
#   - Shared Spack store integrity (symlinks, install_tree)
#   - UV cache mount and per-project workspace writability
#   - Entrypoint resolution in multi-repo mode
#
# Usage:
#   bash container/verify_multi_repo.sh
#
# Prerequisites:
#   - Docker daemon running with NVIDIA runtime
#   - sygaldry/zephyr:base image built
#   - Spack store at default location (42GB artifact)

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
source "${SCRIPT_DIR}/lib/verify_common.sh"

verify_reset_counters

# Unique project IDs to avoid colliding with real projects
TEST_PROJECT_LEGACY="test-multirepo-legacy-$$"
TEST_PROJECT_MULTI="test-multirepo-multi-$$"

# Temp dirs for fake repos
CLEANUP_DIRS=()
cleanup() {
    for d in "${CLEANUP_DIRS[@]}"; do
        rm -rf "${d}" 2>/dev/null || true
    done
    # Clean up test project dirs (best-effort)
    rm -rf "/mnt/data_infra/zephyr_container_infra/${TEST_PROJECT_LEGACY}" 2>/dev/null || true
    rm -rf "/mnt/data_infra/zephyr_container_infra/${TEST_PROJECT_MULTI}" 2>/dev/null || true
}
trap cleanup EXIT

# Run a command inside the container via the launcher and capture output.
# Usage: run_in_container [launcher_flags...] -- <bash_command>
# The bash command runs inside the container via run-job.sh entrypoint.
run_legacy() {
    local cmd="$1"
    SYGALDRY_PROJECT_ID="${TEST_PROJECT_LEGACY}" \
    SYGALDRY_BUILD_IMAGE=never \
        zephyr \
        --entrypoint run-job.sh -- bash -c "${cmd}" 2>/dev/null
}

run_multi() {
    local repo_path="$1"
    local cmd="$2"
    SYGALDRY_PROJECT_ID="${TEST_PROJECT_MULTI}" \
    SYGALDRY_BUILD_IMAGE=never \
        zephyr \
        --repo "${repo_path}" \
        --entrypoint run-job.sh -- bash -c "${cmd}" 2>/dev/null
}

# ============================================================================
# Preflight
# ============================================================================

echo "=== Preflight ==="

# Check Docker is available
if ! verify_require_docker; then
    echo "Skipping integration tests." >&2
    exit 0
fi

# Check image exists
IMAGE="${SYGALDRY_IMAGE:-sygaldry/zephyr:base}"
if ! verify_require_image "${IMAGE}"; then
    echo "ERROR: Image ${IMAGE} not found. Build it first. Skipping integration tests." >&2
    exit 0
fi

echo "  Docker: OK"
echo "  Image: ${IMAGE}"

# Create a fake external repo with a marker file
FAKE_REPO="$(mktemp -d)"
CLEANUP_DIRS+=("${FAKE_REPO}")
echo "integration-test-marker" > "${FAKE_REPO}/MARKER.txt"
FAKE_REPO_NAME="$(basename "${FAKE_REPO}")"
echo "  Fake repo: ${FAKE_REPO} (name: ${FAKE_REPO_NAME})"

# ============================================================================
# Test: Legacy Mode Mount Layout
# ============================================================================

echo ""
echo "=== Legacy Mode Mount Layout ==="

# SYGALDRY_ROOT should be /workspace
result="$(run_legacy 'echo "${SYGALDRY_ROOT:-unset}"')" || true
if [[ "${result}" == "/workspace" ]]; then
    pass "Legacy: SYGALDRY_ROOT=/workspace"
else
    fail "Legacy: SYGALDRY_ROOT=/workspace" "got '${result}'"
fi

# sygaldry entrypoints visible at /workspace
result="$(run_legacy 'test -f /workspace/container/entrypoints/default.sh && echo yes')" || true
if [[ "${result}" == "yes" ]]; then
    pass "Legacy: /workspace/container/entrypoints/default.sh exists"
else
    fail "Legacy: /workspace/container/entrypoints/default.sh exists"
fi

# /opt/spack_store is a directory
result="$(run_legacy 'test -d /opt/spack_store && echo yes')" || true
if [[ "${result}" == "yes" ]]; then
    pass "Legacy: /opt/spack_store is a directory"
else
    fail "Legacy: /opt/spack_store is a directory"
fi

# /opt/uv_cache is a directory
result="$(run_legacy 'test -d /opt/uv_cache && echo yes')" || true
if [[ "${result}" == "yes" ]]; then
    pass "Legacy: /opt/uv_cache is a directory"
else
    fail "Legacy: /opt/uv_cache is a directory"
fi

# UV_CACHE_DIR is set
result="$(run_legacy 'echo "${UV_CACHE_DIR:-unset}"')" || true
if [[ "${result}" == "/opt/uv_cache" ]]; then
    pass "Legacy: UV_CACHE_DIR=/opt/uv_cache"
else
    fail "Legacy: UV_CACHE_DIR=/opt/uv_cache" "got '${result}'"
fi

# ============================================================================
# Test: Multi-Repo Mode Mount Layout
# ============================================================================

echo ""
echo "=== Multi-Repo Mode Mount Layout ==="

# Repo marker file visible
result="$(run_multi "${FAKE_REPO}" "cat /workspace/${FAKE_REPO_NAME}/MARKER.txt")" || true
if [[ "${result}" == "integration-test-marker" ]]; then
    pass "Multi-repo: repo marker file at /workspace/<name>/MARKER.txt"
else
    fail "Multi-repo: repo marker file at /workspace/<name>/MARKER.txt" "got '${result}'"
fi

# SYGALDRY_ROOT should be /opt/sygaldry
result="$(run_multi "${FAKE_REPO}" 'echo "${SYGALDRY_ROOT:-unset}"')" || true
if [[ "${result}" == "/opt/sygaldry" ]]; then
    pass "Multi-repo: SYGALDRY_ROOT=/opt/sygaldry"
else
    fail "Multi-repo: SYGALDRY_ROOT=/opt/sygaldry" "got '${result}'"
fi

# Sygaldry entrypoints visible at /opt/sygaldry
result="$(run_multi "${FAKE_REPO}" 'test -f /opt/sygaldry/container/entrypoints/default.sh && echo yes')" || true
if [[ "${result}" == "yes" ]]; then
    pass "Multi-repo: /opt/sygaldry/container/entrypoints/default.sh exists"
else
    fail "Multi-repo: /opt/sygaldry/container/entrypoints/default.sh exists"
fi

# pkg/zephyr accessible from /opt/sygaldry
result="$(run_multi "${FAKE_REPO}" 'test -f /opt/sygaldry/pkg/zephyr/spack_src.yaml && echo yes')" || true
if [[ "${result}" == "yes" ]]; then
    pass "Multi-repo: /opt/sygaldry/pkg/zephyr/spack_src.yaml accessible"
else
    fail "Multi-repo: /opt/sygaldry/pkg/zephyr/spack_src.yaml accessible"
fi

# Working directory is /workspace/<repo_name>
result="$(run_multi "${FAKE_REPO}" 'pwd')" || true
if [[ "${result}" == "/workspace/${FAKE_REPO_NAME}" ]]; then
    pass "Multi-repo: workdir is /workspace/<name>"
else
    fail "Multi-repo: workdir is /workspace/<name>" "got '${result}'"
fi

# /workspace is writable
result="$(run_multi "${FAKE_REPO}" 'touch /workspace/.write-test && echo yes && rm /workspace/.write-test')" || true
if [[ "${result}" == "yes" ]]; then
    pass "Multi-repo: /workspace is writable"
else
    fail "Multi-repo: /workspace is writable"
fi

# /opt/sygaldry is read-only
result="$(run_multi "${FAKE_REPO}" 'touch /opt/sygaldry/.write-test 2>&1 && echo writable || echo readonly')" || true
if [[ "${result}" == *"readonly"* ]] || [[ "${result}" == *"Read-only"* ]]; then
    pass "Multi-repo: /opt/sygaldry is read-only"
else
    fail "Multi-repo: /opt/sygaldry is read-only" "got '${result}'"
fi

# ============================================================================
# Test: Shared Spack Store Integrity (protects the 42GB artifact)
# ============================================================================

echo ""
echo "=== Shared Spack Store Integrity ==="

# install_tree exists
result="$(run_multi "${FAKE_REPO}" 'test -d /opt/spack_store/install_tree && echo yes')" || true
if [[ "${result}" == "yes" ]]; then
    pass "Spack: /opt/spack_store/install_tree exists"
else
    fail "Spack: /opt/spack_store/install_tree exists"
fi

# view is a symlink
result="$(run_multi "${FAKE_REPO}" 'test -L /opt/spack_store/view && echo yes')" || true
if [[ "${result}" == "yes" ]]; then
    pass "Spack: /opt/spack_store/view is a symlink"
else
    fail "Spack: /opt/spack_store/view is a symlink"
fi

# view target starts with /opt/spack_store/
result="$(run_multi "${FAKE_REPO}" 'readlink /opt/spack_store/view')" || true
if [[ "${result}" == /opt/spack_store/* ]]; then
    pass "Spack: view symlink target is under /opt/spack_store/"
else
    fail "Spack: view symlink target is under /opt/spack_store/" "got '${result}'"
fi

# ============================================================================
# Test: UV Cache Shared, Workspace Writable
# ============================================================================

echo ""
echo "=== UV Cache and Workspace ==="

# UV_CACHE_DIR in multi-repo mode
result="$(run_multi "${FAKE_REPO}" 'echo "${UV_CACHE_DIR:-unset}"')" || true
if [[ "${result}" == "/opt/uv_cache" ]]; then
    pass "Multi-repo: UV_CACHE_DIR=/opt/uv_cache"
else
    fail "Multi-repo: UV_CACHE_DIR=/opt/uv_cache" "got '${result}'"
fi

# Can create a venv dir under /workspace (per-project location)
result="$(run_multi "${FAKE_REPO}" 'mkdir -p /workspace/.venv-test && test -d /workspace/.venv-test && echo yes && rmdir /workspace/.venv-test')" || true
if [[ "${result}" == "yes" ]]; then
    pass "Multi-repo: can create venv dir under /workspace"
else
    fail "Multi-repo: can create venv dir under /workspace"
fi

# ============================================================================
# Test: Env Vars Consistent Between Modes
# ============================================================================

echo ""
echo "=== Env Var Consistency ==="

# SYGALDRY_IN_CONTAINER is set in both modes
for mode_label in "Legacy" "Multi-repo"; do
    if [[ "${mode_label}" == "Legacy" ]]; then
        result="$(run_legacy 'echo "${SYGALDRY_IN_CONTAINER:-unset}"')" || true
    else
        result="$(run_multi "${FAKE_REPO}" 'echo "${SYGALDRY_IN_CONTAINER:-unset}"')" || true
    fi
    if [[ "${result}" == "1" ]]; then
        pass "${mode_label}: SYGALDRY_IN_CONTAINER=1"
    else
        fail "${mode_label}: SYGALDRY_IN_CONTAINER=1" "got '${result}'"
    fi
done

# HF_HOME is set in both modes
for mode_label in "Legacy" "Multi-repo"; do
    if [[ "${mode_label}" == "Legacy" ]]; then
        result="$(run_legacy 'echo "${HF_HOME:-unset}"')" || true
    else
        result="$(run_multi "${FAKE_REPO}" 'echo "${HF_HOME:-unset}"')" || true
    fi
    if [[ "${result}" == "/opt/hf_cache" ]]; then
        pass "${mode_label}: HF_HOME=/opt/hf_cache"
    else
        fail "${mode_label}: HF_HOME=/opt/hf_cache" "got '${result}'"
    fi
done

# ============================================================================
# Summary
# ============================================================================

verify_print_summary "Integration Test Summary"
verify_exit_on_failures
