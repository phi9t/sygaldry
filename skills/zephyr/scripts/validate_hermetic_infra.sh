#!/bin/bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SKILL_ROOT

TARGET_ROOT="${1:-${SKILL_ROOT}}"
readonly TARGET_ROOT

log() {
    echo "[validate-hermetic] $*" >&2
}

err() {
    log "ERROR: $*"
    exit 1
}

[[ -d "${TARGET_ROOT}" ]] || err "Target root not found: ${TARGET_ROOT}"

required_paths=(
    "${TARGET_ROOT}/SKILL.md"
    "${TARGET_ROOT}/agents/openai.yaml"
    "${TARGET_ROOT}/scripts/zephyr_vendor_infra.sh"
    "${TARGET_ROOT}/assets/zephyr-container-infra/bin/repoctl"
    "${TARGET_ROOT}/assets/zephyr-container-infra/bin/jobctl"
    "${TARGET_ROOT}/assets/zephyr-container-infra/container/launch_container.sh"
    "${TARGET_ROOT}/assets/zephyr-container-infra/infra.yaml"
)

for path in "${required_paths[@]}"; do
    [[ -e "${path}" ]] || err "Missing required path: ${path}"
done

vendor_script="${TARGET_ROOT}/scripts/zephyr_vendor_infra.sh"
grep -q 'KIT_SRC="${SKILL_ROOT}/assets/zephyr-container-infra"' "${vendor_script}" || {
    err "zephyr_vendor_infra.sh must source kit from skill assets/"
}

if ! command -v rg >/dev/null 2>&1; then
    err "rg is required for hermetic validation"
fi

forbidden_patterns=(
    "/mnt/data_infra/wor""kspace/sygaldry"
    "/home/phi9t/wor""kspace/sygaldry"
    "to""ols/zephyr_vendor_infra.sh"
    "portable/zephyr-container-infra"
)

for pattern in "${forbidden_patterns[@]}"; do
    if rg -n --hidden --glob '*.md' --glob '*.sh' --glob '*.py' --glob '*.yaml' --glob '*.yml' \
        --glob '!**/scripts/validate_hermetic_infra.sh' \
        --glob '!assets/zephyr-container-infra/README.md' \
        --glob '!assets/zephyr-container-infra/Dockerfile.zephyr' \
        "${pattern}" "${TARGET_ROOT}" >/tmp/zephyr-hermetic-hits.txt 2>/dev/null; then
        cat /tmp/zephyr-hermetic-hits.txt >&2
        err "Forbidden repo-coupled pattern detected: ${pattern}"
    fi
done

log "Hermetic validation passed for ${TARGET_ROOT}"
