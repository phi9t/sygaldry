#!/bin/bash
#
# Unit tests for launch_container.sh compatibility shim
#
# Layer 1: no Docker required. Verifies that the shim delegates to the
# `zephyr` binary with the expected argument translation.

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly LAUNCHER="${REPO_ROOT}/container/launch_container.sh"

TESTS_RUN=0
TESTS_PASSED=0
FAILURES=0

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "  PASS: $1"
}

fail() {
    FAILURES=$((FAILURES + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
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

run_with_mock_zephyr() {
    local mock_dir
    mock_dir="$(mktemp -d)"
    cat > "${mock_dir}/zephyr" <<'EOF'
#!/bin/bash
printf 'ZEPHYR_ARGS:'
printf '%s ' "$@"
printf '\n'
EOF
    chmod +x "${mock_dir}/zephyr"
    PATH="${mock_dir}:${PATH}" SYGALDRY_HOME="" /bin/bash "${LAUNCHER}" "$@" 2>&1
    local rc=$?
    rm -rf "${mock_dir}"
    return ${rc}
}

# shellcheck disable=SC2120  # accepts optional passthrough args like run_with_mock_zephyr
run_without_zephyr() {
    local empty_dir
    empty_dir="$(mktemp -d)"
    PATH="${empty_dir}" SYGALDRY_HOME="" /bin/bash "${LAUNCHER}" "$@" 2>&1
    local rc=$?
    rm -rf "${empty_dir}"
    return ${rc}
}

echo ""
echo "=== launch_container.sh shim delegation ==="

result="$(run_with_mock_zephyr)"
assert_contains "${result}" "DEPRECATED: container/launch_container.sh is a compatibility shim" \
    "shim prints deprecation warning"
assert_contains "${result}" "ZEPHYR_ARGS:shell " \
    "default invocation delegates to 'zephyr shell'"

result="$(run_with_mock_zephyr -- python train.py)"
assert_contains "${result}" "ZEPHYR_ARGS:run -- python train.py " \
    "passthrough command delegates to 'zephyr run -- ...'"

result="$(run_with_mock_zephyr --entrypoint verify-gpu.sh)"
assert_contains "${result}" "ZEPHYR_ARGS:--entrypoint verify-gpu.sh shell " \
    "entrypoint-only invocation delegates to shell with global entrypoint flag"

result="$(run_with_mock_zephyr --entrypoint run-job.sh -- python train.py)"
assert_contains "${result}" "ZEPHYR_ARGS:--entrypoint run-job.sh run -- python train.py " \
    "entrypoint plus passthrough delegates to run subcommand"

result="$(run_with_mock_zephyr --repo /tmp/example-repo)"
assert_contains "${result}" "ZEPHYR_ARGS:--repo /tmp/example-repo shell " \
    "repo flag is passed through to zephyr shell"

result="$(run_with_mock_zephyr --print-effective-config)"
assert_contains "${result}" "ZEPHYR_ARGS:--print-effective-config shell " \
    "--print-effective-config is preserved"

set +e
result="$(run_without_zephyr 2>&1)"
rc=$?
set -e
assert_eq "${rc}" "1" "launcher exits non-zero when zephyr is unavailable"
assert_contains "${result}" "zephyr binary not found" \
    "missing zephyr error explains how to build the binary"

echo ""
echo "=== Summary ==="
echo "Passed: ${TESTS_PASSED}/${TESTS_RUN}"
if [[ ${FAILURES} -gt 0 ]]; then
    exit 1
fi
