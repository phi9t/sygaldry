#!/bin/bash
# Contract checks that guard against Zephyr infra doc/script drift.

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT

FAILURES=0

pass() {
    echo "[contract] PASS: $*" >&2
}

fail() {
    echo "[contract] FAIL: $*" >&2
    ((FAILURES++)) || true
}

require_file() {
    local path="$1"
    if [[ -f "${path}" ]]; then
        pass "file exists: ${path}"
    else
        fail "missing file: ${path}"
    fi
}

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if rg -Fq "${pattern}" "${file}"; then
        pass "${message}"
    else
        fail "${message}"
    fi
}

cd "${REPO_ROOT}"

require_file "container/ZEPHYR_SYSTEM_DESIGN.md"
require_file "container/ZEPHYR_UNIFIED_CACHE_SYSTEM_DESIGN.md"
require_file "SYSTEM_DESIGN.md"
require_file "container/ZEPHYR_CONTAINER_INFRA_REQUIREMENTS.md"
require_file "container/PRODUCTION_READINESS.md"
require_file "pkg/zephyr/build.sh"
require_file "tools/spack_src.yaml"
require_file "pkg/zephyr/spack_src.yaml"

# tools/spack_src.yaml must be a symlink to pkg/zephyr/spack_src.yaml.
if [[ -L "tools/spack_src.yaml" ]]; then
    local_target="$(readlink "tools/spack_src.yaml")"
    if [[ "${local_target}" == *"pkg/zephyr/spack_src.yaml"* ]]; then
        pass "tools/spack_src.yaml is symlink to pkg/zephyr/spack_src.yaml"
    else
        fail "tools/spack_src.yaml symlink target unexpected: ${local_target}"
    fi
elif cmp -s "tools/spack_src.yaml" "pkg/zephyr/spack_src.yaml"; then
    pass "tools/spack_src.yaml matches pkg/zephyr/spack_src.yaml (not yet symlinked)"
else
    fail "tools/spack_src.yaml diverges from pkg/zephyr/spack_src.yaml"
fi

# Unified-cache doc should be a deprecation pointer to canonical design doc.
require_pattern "container/ZEPHYR_UNIFIED_CACHE_SYSTEM_DESIGN.md" "Deprecated" \
    "unified-cache doc marked deprecated"
require_pattern "container/ZEPHYR_UNIFIED_CACHE_SYSTEM_DESIGN.md" "container/ZEPHYR_SYSTEM_DESIGN.md" \
    "unified-cache doc points to canonical design doc"

# Root design doc must explicitly delegate infra contract authority.
require_pattern "SYSTEM_DESIGN.md" "Authoritative infra contract" \
    "root design doc declares authoritative infra contract"
require_pattern "SYSTEM_DESIGN.md" "container/ZEPHYR_SYSTEM_DESIGN.md" \
    "root design doc references canonical infra design doc"

require_pattern "container/ZEPHYR_CONTAINER_INFRA_REQUIREMENTS.md" "Deprecated" \
    "requirements doc marked as deprecated"
require_pattern "container/PRODUCTION_READINESS.md" "Deprecated" \
    "production readiness doc marked as deprecated"

# Launcher and design doc must agree on ZEPHYR_BUILD_ROOT default string.
LAUNCH_BUILD_ROOT_DEFAULT="$(sed -n 's/^readonly ZEPHYR_BUILD_ROOT="${ZEPHYR_BUILD_ROOT:-\(.*\)}"/\1/p' container/launch_container.sh)"
if [[ -z "${LAUNCH_BUILD_ROOT_DEFAULT}" ]]; then
    fail "unable to extract ZEPHYR_BUILD_ROOT default from launcher"
else
    pass "launcher ZEPHYR_BUILD_ROOT default extracted: ${LAUNCH_BUILD_ROOT_DEFAULT}"
    DOC_BUILD_LINE="\`ZEPHYR_BUILD_ROOT\` (default \`${LAUNCH_BUILD_ROOT_DEFAULT}\`)"
    if rg -Fq "${DOC_BUILD_LINE}" container/ZEPHYR_SYSTEM_DESIGN.md; then
        pass "design doc matches launcher ZEPHYR_BUILD_ROOT default"
    else
        fail "design doc does not match launcher ZEPHYR_BUILD_ROOT default"
    fi
fi

# Stale token guardrails in docs.
DOC_SCOPE=(
    "README.md"
    "SYSTEM_DESIGN.md"
    "container/ZEPHYR_SYSTEM_DESIGN.md"
    "container/ZEPHYR_HACKERS_GUIDE.md"
    "container/ZEPHYR_CONTAINER_INFRA_REQUIREMENTS.md"
    "container/PRODUCTION_READINESS.md"
    "skills/zephyr-container-exec/SKILL.md"
    "skills/zephyr-container-exec/VALIDATION.md"
    "example_repo_scoped_zephyr_skill/SKILL.md"
)

forbidden_token_check() {
    local token="$1"
    local description="$2"
    if rg -n --no-heading -F "${token}" "${DOC_SCOPE[@]}" >/dev/null 2>&1; then
        fail "stale token present (${description}): ${token}"
    else
        pass "stale token absent (${description}): ${token}"
    fi
}

forbidden_token_check "SYGALDRY_GPU" "legacy GPU flag"
forbidden_token_check "SYGALDRY_REQUIRE_GPU" "legacy GPU-required flag"
forbidden_token_check "/opt/bazel_cache/uv" "old UV cache path"
forbidden_token_check "/opt/bazel_cache/hf" "old HF cache path"
forbidden_token_check "sygaldry-build/" "deprecated build root name"
forbidden_token_check "skills/zephyr-container-exec/scripts/" "non-existent skill helper scripts"

if [[ ${FAILURES} -ne 0 ]]; then
    echo "[contract] ${FAILURES} contract check(s) failed." >&2
    exit 1
fi

echo "[contract] All contract checks passed." >&2
exit 0
