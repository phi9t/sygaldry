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
    "${TARGET_ROOT}/scripts/zephyr_mlsys_vendor.sh"
    "${TARGET_ROOT}/scripts/package_mlsys.sh"
    "${TARGET_ROOT}/assets/zephyr-mlsys-runtime/bin/launch-mlsys.sh"
    "${TARGET_ROOT}/assets/zephyr-mlsys-runtime/container/entrypoint.sh"
    "${TARGET_ROOT}/assets/zephyr-mlsys-runtime/container/run-job.sh"
)

for path in "${required_paths[@]}"; do
    [[ -e "${path}" ]] || err "Missing required path: ${path}"
done

for env_file in "${TARGET_ROOT}/envs/"*.yaml; do
    [[ -e "${env_file}" ]] || err "No env yaml files found under envs/"
    [[ ! -L "${env_file}" ]] || err "Env definition must not be symlink: ${env_file}"
done

if ! command -v rg >/dev/null 2>&1; then
    err "rg is required for hermetic validation"
fi

repo_tools_pat="to""ols/"
vendor_pat="\\.sygal""dry/"
abs_repo_one="/mnt/data_infra/wor""kspace/sygaldry"
abs_repo_two="/home/phi9t/wor""kspace/sygaldry"
opt_pat="/opt/sygal""dry/"

for pattern in \
    "${repo_tools_pat}" \
    "${vendor_pat}" \
    "${abs_repo_one}" \
    "${abs_repo_two}" \
    "${opt_pat}"; do
    if rg -n --hidden \
        --glob '*.md' \
        --glob '*.sh' \
        --glob '*.py' \
        --glob '*.yaml' \
        --glob '*.yml' \
        --glob '!scripts/validate_hermetic_mlsys.sh' \
        --glob '!scripts/validate_hermetic_infra.sh' \
        --glob '!scripts/zephyr_vendor_infra.sh' \
        --glob '!assets/zephyr-container-infra/**' \
        "${pattern}" "${TARGET_ROOT}" >/tmp/zephyr-mlsys-hermetic-hits.txt 2>/dev/null; then
        cat /tmp/zephyr-mlsys-hermetic-hits.txt >&2
        err "Forbidden repo-coupled pattern detected: ${pattern}"
    fi
done

log "Hermetic validation passed for ${TARGET_ROOT}"
