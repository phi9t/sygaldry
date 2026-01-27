#!/bin/bash
#
# Unit Tests for launch_container.sh
# ===================================
#
# Layer 1: No Docker required. Tests argument parsing, config resolution,
# docker arg generation, and entrypoint SYGALDRY_ROOT usage.
#
# Usage:
#   bash container/launch_container_test.sh
#
# Each test runs in its own subshell so that readonly variables from sourcing
# launch_container.sh don't collide between tests.

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT

TESTS_RUN=0
TESTS_PASSED=0
FAILURES=0

# ============================================================================
# Test Helpers
# ============================================================================

log_test() {
    echo "[test] $*" >&2
}

pass() {
    ((TESTS_PASSED++)) || true
    ((TESTS_RUN++)) || true
    echo "  PASS: $1"
}

fail() {
    ((FAILURES++)) || true
    ((TESTS_RUN++)) || true
    echo "  FAIL: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        pass "${msg}"
    else
        fail "${msg}" "expected '${expected}', got '${actual}'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        pass "${msg}"
    else
        fail "${msg}" "missing '${needle}'"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if [[ "${haystack}" != *"${needle}"* ]]; then
        pass "${msg}"
    else
        fail "${msg}" "unexpected '${needle}'"
    fi
}

assert_file_contains() {
    local file="$1" pattern="$2" msg="$3"
    if grep -q "${pattern}" "${file}" 2>/dev/null; then
        pass "${msg}"
    else
        fail "${msg}" "file '${file}' does not contain '${pattern}'"
    fi
}

assert_file_not_contains() {
    local file="$1" pattern="$2" msg="$3"
    if ! grep -q "${pattern}" "${file}" 2>/dev/null; then
        pass "${msg}"
    else
        fail "${msg}" "file '${file}' unexpectedly contains '${pattern}'"
    fi
}

# ============================================================================
# Mock Setup
# ============================================================================
# Write mock scripts to a temp dir so they work across subshells.

MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "${MOCK_DIR}"' EXIT

# Mock docker: responds to "docker info" with nvidia runtime, everything else is no-op
cat > "${MOCK_DIR}/docker" << 'MOCK_DOCKER'
#!/bin/bash
case "$1" in
    info)
        echo "Runtimes: runc nvidia"
        ;;
    image)
        # "docker image inspect" -- pretend image exists
        echo "{}"
        ;;
    run)
        # Capture the full command for inspection
        echo "DOCKER_RUN: $*"
        ;;
    build)
        echo "DOCKER_BUILD: $*"
        ;;
    *)
        echo "MOCK_DOCKER: $*"
        ;;
esac
MOCK_DOCKER
chmod +x "${MOCK_DIR}/docker"

# Mock nvidia-smi
cat > "${MOCK_DIR}/nvidia-smi" << 'MOCK_NVIDIA'
#!/bin/bash
echo "NVIDIA-SMI 560.35.03    Driver Version: 560.35.03    CUDA Version: 12.9"
MOCK_NVIDIA
chmod +x "${MOCK_DIR}/nvidia-smi"

# Helper: source launch_container.sh in a fresh bash process with mocks on PATH.
# Usage: run_with_launcher [env_var=value ...] -- 'shell command'
# Must use bash -c because () subshells don't set BASH_SOURCE correctly for source.
run_with_launcher() {
    local env_args=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        env_args+=("$1")
        shift
    done
    [[ "${1:-}" == "--" ]] && shift
    local cmd="${1:-true}"

    env PATH="${MOCK_DIR}:${PATH}" "${env_args[@]}" \
        bash -c "source '${SCRIPT_DIR}/launch_container.sh'; ${cmd}" 2>/dev/null
}

# Helper: call build_docker_args with a config struct in a fresh bash process.
# Usage: call_build_docker_args [env=val ...] -- 'declare -A CFG=(...); build_docker_args CFG'
call_build_docker_args() {
    local env_args=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        env_args+=("$1")
        shift
    done
    [[ "${1:-}" == "--" ]] && shift
    local cfg_script="$1"

    env PATH="${MOCK_DIR}:${PATH}" "${env_args[@]}" \
        bash -c "source '${SCRIPT_DIR}/launch_container.sh'; ${cfg_script}" 2>/dev/null
}

# ============================================================================
# Test: Config Resolution Defaults
# ============================================================================

echo ""
echo "=== Config Resolution: Defaults ==="

# SYGALDRY_HOME defaults to PROJECT_ROOT
result="$(run_with_launcher -- 'echo "${SYGALDRY_HOME}"' 2>/dev/null)"
expected_repo_root="$(realpath "${REPO_ROOT}")"
assert_eq "${result}" "${expected_repo_root}" "SYGALDRY_HOME defaults to PROJECT_ROOT"

# HOST_SPACK_STORE defaults to builder-scoped spack_store
result="$(run_with_launcher -- 'echo "${HOST_SPACK_STORE}"' 2>/dev/null)"
assert_contains "${result}" "zephyr_container_infra/sygaldry/spack_store" \
    "HOST_SPACK_STORE defaults to builder-scoped spack_store"

# HOST_HF_CACHE defaults to shared hf_cache
result="$(run_with_launcher -- 'echo "${HOST_HF_CACHE}"' 2>/dev/null)"
assert_contains "${result}" "zephyr_container_infra/shared/hf_cache" \
    "HOST_HF_CACHE defaults to shared hf_cache"

# HOST_UV_CACHE defaults to shared uv_cache
result="$(run_with_launcher -- 'echo "${HOST_UV_CACHE}"' 2>/dev/null)"
assert_contains "${result}" "zephyr_container_infra/shared/uv_cache" \
    "HOST_UV_CACHE defaults to shared uv_cache"

# HOST_WORKSPACE is per-project
result="$(run_with_launcher -- 'echo "${HOST_WORKSPACE}"' 2>/dev/null)"
assert_contains "${result}" "/workspace" \
    "HOST_WORKSPACE ends with /workspace"

# ============================================================================
# Test: Config Resolution Overrides
# ============================================================================

echo ""
echo "=== Config Resolution: Overrides ==="

# SYGALDRY_SPACK_STORE overrides HOST_SPACK_STORE
result="$(run_with_launcher "SYGALDRY_SPACK_STORE=/custom/spack" -- \
    'echo "${HOST_SPACK_STORE}"' 2>/dev/null)"
assert_eq "${result}" "/custom/spack" \
    "SYGALDRY_SPACK_STORE overrides HOST_SPACK_STORE"

# SYGALDRY_UV_CACHE overrides HOST_UV_CACHE
result="$(run_with_launcher "SYGALDRY_UV_CACHE=/custom/uv" -- \
    'echo "${HOST_UV_CACHE}"' 2>/dev/null)"
assert_eq "${result}" "/custom/uv" \
    "SYGALDRY_UV_CACHE overrides HOST_UV_CACHE"

# SYGALDRY_HF_CACHE overrides HOST_HF_CACHE
result="$(run_with_launcher "SYGALDRY_HF_CACHE=/custom/hf" -- \
    'echo "${HOST_HF_CACHE}"' 2>/dev/null)"
assert_eq "${result}" "/custom/hf" \
    "SYGALDRY_HF_CACHE overrides HOST_HF_CACHE"

# SYGALDRY_HOME can be overridden
result="$(run_with_launcher "SYGALDRY_HOME=/custom/sygaldry" -- \
    'echo "${SYGALDRY_HOME}"' 2>/dev/null)"
assert_eq "${result}" "/custom/sygaldry" \
    "SYGALDRY_HOME override works"

# ============================================================================
# Test: Docker Arg Generation -- Legacy Mode
# ============================================================================

echo ""
echo "=== Docker Arg Generation: Legacy Mode ==="

# Build args for legacy mode using config struct
LEGACY_ARGS="$(call_build_docker_args -- '
declare -A CFG=(
    [monorepo_home]=/tmp/mock_home
    [spack_store]=/tmp/mock_spack
    [bazel_cache]=/tmp/mock_bazel
    [hf_cache]=/tmp/mock_hf
    [uv_cache]=/tmp/mock_uv
    [entrypoint_path]=/workspace/container/entrypoints/default.sh
    [mode]=legacy
    [project_root]=/tmp/mock_project
    [spack_baked]=false
    [run_id]=test-run
    [lease_mode]=warn
    [cache_profile]=shared
)
build_docker_args CFG
' 2>/dev/null || true)"

assert_contains "${LEGACY_ARGS}" "--volume=/tmp/mock_project:/workspace" \
    "Legacy: project mounted at /workspace"
assert_contains "${LEGACY_ARGS}" "--workdir=/workspace" \
    "Legacy: workdir is /workspace"
assert_contains "${LEGACY_ARGS}" "--env=SYGALDRY_ROOT=/workspace" \
    "Legacy: SYGALDRY_ROOT=/workspace"
assert_not_contains "${LEGACY_ARGS}" "/opt/sygaldry" \
    "Legacy: no /opt/sygaldry mount"
assert_contains "${LEGACY_ARGS}" "--volume=/tmp/mock_spack:/opt/spack_store" \
    "Legacy: spack store mounted"
assert_contains "${LEGACY_ARGS}" "--volume=/tmp/mock_uv:/opt/uv_cache" \
    "Legacy: uv cache mounted"
assert_contains "${LEGACY_ARGS}" "--env=UV_CACHE_DIR=/opt/uv_cache" \
    "Legacy: UV_CACHE_DIR set"
assert_contains "${LEGACY_ARGS}" "--env=HF_HOME=/opt/hf_cache" \
    "Legacy: HF_HOME set"
assert_contains "${LEGACY_ARGS}" "--entrypoint=/workspace/container/entrypoints/default.sh" \
    "Legacy: entrypoint path"

# ============================================================================
# Test: Docker Arg Generation -- Multi-Repo Mode
# ============================================================================

echo ""
echo "=== Docker Arg Generation: Multi-Repo Mode ==="

MULTI_ARGS="$(call_build_docker_args -- '
declare -A CFG=(
    [monorepo_home]=/tmp/mock_home
    [spack_store]=/tmp/mock_spack
    [bazel_cache]=/tmp/mock_bazel
    [hf_cache]=/tmp/mock_hf
    [uv_cache]=/tmp/mock_uv
    [entrypoint_path]=/opt/sygaldry/container/entrypoints/default.sh
    [mode]=multi-repo
    [sygaldry_home]=/tmp/mock_sygaldry
    [workspace]=/tmp/mock_workspace
    [repo]=/tmp/mock_repo
    [repo_name]=myrepo
    [spack_baked]=false
    [run_id]=test-run
    [lease_mode]=warn
    [cache_profile]=shared
)
build_docker_args CFG
' 2>/dev/null || true)"

assert_contains "${MULTI_ARGS}" "--volume=/tmp/mock_sygaldry:/opt/sygaldry:ro" \
    "Multi-repo: sygaldry mounted read-only at /opt/sygaldry"
assert_contains "${MULTI_ARGS}" "--volume=/tmp/mock_workspace:/workspace" \
    "Multi-repo: persistent workspace mounted"
assert_contains "${MULTI_ARGS}" "--volume=/tmp/mock_repo:/workspace/myrepo" \
    "Multi-repo: repo mounted at /workspace/<name>"
assert_contains "${MULTI_ARGS}" "--workdir=/workspace/myrepo" \
    "Multi-repo: workdir is /workspace/<name>"
assert_contains "${MULTI_ARGS}" "--env=SYGALDRY_ROOT=/workspace/myrepo" \
    "Multi-repo: SYGALDRY_ROOT=/workspace/<name>"
assert_contains "${MULTI_ARGS}" "--volume=/tmp/mock_spack:/opt/spack_store" \
    "Multi-repo: spack store mounted"
assert_contains "${MULTI_ARGS}" "--volume=/tmp/mock_uv:/opt/uv_cache" \
    "Multi-repo: uv cache mounted"
assert_contains "${MULTI_ARGS}" "--env=UV_CACHE_DIR=/opt/uv_cache" \
    "Multi-repo: UV_CACHE_DIR set"
assert_contains "${MULTI_ARGS}" "--env=HF_HOME=/opt/hf_cache" \
    "Multi-repo: HF_HOME set"
assert_contains "${MULTI_ARGS}" "--entrypoint=/opt/sygaldry/container/entrypoints/default.sh" \
    "Multi-repo: entrypoint from /opt/sygaldry"

# ============================================================================
# Test: Shared Mounts Present in Both Modes
# ============================================================================

echo ""
echo "=== Shared Mounts in Both Modes ==="

for mode_label in "Legacy" "Multi-repo"; do
    if [[ "${mode_label}" == "Legacy" ]]; then
        args="${LEGACY_ARGS}"
    else
        args="${MULTI_ARGS}"
    fi
    assert_contains "${args}" "--volume=/tmp/mock_home:/home/kvothe" \
        "${mode_label}: home mounted"
    assert_contains "${args}" "--volume=/tmp/mock_bazel:/opt/bazel_cache" \
        "${mode_label}: bazel cache mounted"
    assert_contains "${args}" "--volume=/tmp/mock_hf:/opt/hf_cache" \
        "${mode_label}: hf cache mounted"
    assert_contains "${args}" "--env=SYGALDRY_IN_CONTAINER=1" \
        "${mode_label}: SYGALDRY_IN_CONTAINER=1 set"
    assert_contains "${args}" "--runtime=nvidia" \
        "${mode_label}: nvidia runtime"
    assert_contains "${args}" "--gpus=all" \
        "${mode_label}: all gpus"
done

# ============================================================================
# Test: Entrypoint Files Use SYGALDRY_ROOT (not hardcoded /workspace/pkg/zephyr)
# ============================================================================

echo ""
echo "=== Entrypoint SYGALDRY_ROOT Usage ==="

# The shared lib container/lib/spack_init.sh contains SYGALDRY_ROOT references.
# Entrypoints that source it inherit the reference.
assert_file_contains "${REPO_ROOT}/container/lib/spack_init.sh" 'SYGALDRY_ROOT' \
    "spack_init.sh: references SYGALDRY_ROOT"

ENTRYPOINTS=(
    "container/entrypoints/default.sh"
    "container/entrypoints/verify-spack.sh"
    "container/entrypoints/verify-gpu.sh"
    "container/entrypoints/spack-build.sh"
)

for ep in "${ENTRYPOINTS[@]}"; do
    ep_path="${REPO_ROOT}/${ep}"
    ep_name="$(basename "${ep}")"

    # Entrypoints either reference SYGALDRY_ROOT directly or source the shared lib
    if grep -q 'SYGALDRY_ROOT' "${ep_path}" 2>/dev/null || grep -q 'spack_init.sh' "${ep_path}" 2>/dev/null; then
        pass "${ep_name}: references SYGALDRY_ROOT (directly or via shared lib)"
    else
        fail "${ep_name}: references SYGALDRY_ROOT (directly or via shared lib)"
    fi
    assert_file_not_contains "${ep_path}" '"/workspace/pkg/zephyr"' \
        "${ep_name}: no hardcoded /workspace/pkg/zephyr string literal"
done

# Also check verify_epilogue.sh
assert_file_contains "${REPO_ROOT}/container/verify_epilogue.sh" 'SYGALDRY_ROOT' \
    "verify_epilogue.sh: references SYGALDRY_ROOT"

# Also check pkg/zephyr/verify.sh
assert_file_contains "${REPO_ROOT}/pkg/zephyr/verify.sh" 'SYGALDRY_ROOT' \
    "pkg/zephyr/verify.sh: references SYGALDRY_ROOT"

# ============================================================================
# Test: bin/sygaldry wrapper exists and is executable
# ============================================================================

echo ""
echo "=== bin/sygaldry Wrapper ==="

if [[ -x "${REPO_ROOT}/bin/sygaldry" ]]; then
    pass "bin/sygaldry exists and is executable"
else
    fail "bin/sygaldry exists and is executable"
fi

assert_file_contains "${REPO_ROOT}/bin/sygaldry" 'SYGALDRY_HOME' \
    "bin/sygaldry: sets SYGALDRY_HOME"
assert_file_contains "${REPO_ROOT}/bin/sygaldry" 'launch_container.sh' \
    "bin/sygaldry: invokes launch_container.sh"

# ============================================================================
# Test: UV Cache Defaults Updated
# ============================================================================

echo ""
echo "=== UV Cache Configuration ==="

assert_file_contains "${REPO_ROOT}/container/entrypoints/hf-download.sh" \
    '/opt/uv_cache' \
    "hf-download.sh: UV_CACHE_DIR references /opt/uv_cache"

assert_file_not_contains "${REPO_ROOT}/container/entrypoints/hf-download.sh" \
    '/opt/bazel_cache/uv_cache' \
    "hf-download.sh: no old /opt/bazel_cache/uv_cache reference"

# ============================================================================
# Test: launch_container.sh env passthrough includes SYGALDRY_ROOT
# ============================================================================

echo ""
echo "=== Launcher Env Passthrough ==="

assert_file_contains "${REPO_ROOT}/container/launch_container.sh" \
    'SYGALDRY_ROOT=' \
    "launch_container.sh: passes SYGALDRY_ROOT to container"

assert_file_contains "${REPO_ROOT}/container/launch_container.sh" \
    'UV_CACHE_DIR=' \
    "launch_container.sh: passes UV_CACHE_DIR to container"

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "========================================"
echo " Unit Test Summary"
echo "========================================"
echo " Tests run:    ${TESTS_RUN}"
echo " Passed:       ${TESTS_PASSED}"
echo " Failed:       ${FAILURES}"
echo "========================================"

if [[ ${FAILURES} -ne 0 ]]; then
    exit 1
fi
exit 0
