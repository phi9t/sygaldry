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

cd "${REPO_ROOT}"

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

# Stale token guardrails in remaining docs.
DOC_SCOPE=(
    "foundation.org"
    "example_repo_scoped_zephyr_skill/SKILL.md"
    "skills/zephyr/SKILL.md"
    "skills/nvidia-container-troubleshooting/SKILL.md"
    "temporal/skills/temporal-orchestration/SKILL.md"
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
