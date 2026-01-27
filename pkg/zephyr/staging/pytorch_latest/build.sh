#!/bin/bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

SOURCE_YAML="${SCRIPT_DIR}/spack_src.yaml"
readonly SOURCE_YAML

REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
readonly REPO_ROOT

STAGE_TOOL="${REPO_ROOT}/tools/zephyr_stage_spack.sh"
readonly STAGE_TOOL

if [[ ! -f "${SOURCE_YAML}" ]]; then
    echo "ERROR: missing staging manifest: ${SOURCE_YAML}" >&2
    exit 1
fi

if [[ ! -x "${STAGE_TOOL}" ]]; then
    echo "ERROR: missing stage tool: ${STAGE_TOOL}" >&2
    exit 1
fi

RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
readonly RUN_ID

RUN_ROOT_BASE="${REPO_ROOT}/outputs/spack_stage"
if [[ ! -d "${RUN_ROOT_BASE}" ]] && ! mkdir -p "${RUN_ROOT_BASE}" 2>/dev/null; then
    RUN_ROOT_BASE="/tmp/zephyr_spack_stage"
fi
readonly RUN_ROOT_BASE

RUN_ROOT="${RUN_ROOT_BASE}/${RUN_ID}"
readonly RUN_ROOT

FORBIDDEN_NAMES="py-jax,py-jaxlib,jax,jaxlib,llvm"
readonly FORBIDDEN_NAMES

SPECS=(
    "py-torch@2.9.0+cuda+nccl+distributed cuda_arch=61,75,80,86,89,90"
    "py-torchvision@0.24.0"
    "py-torchaudio@2.9.0"
)
readonly SPECS

exec "${STAGE_TOOL}" \
    --source-yaml "${SOURCE_YAML}" \
    --run-root "${RUN_ROOT}" \
    --forbidden-names "${FORBIDDEN_NAMES}" \
    --spec "${SPECS[0]}" \
    --spec "${SPECS[1]}" \
    --spec "${SPECS[2]}" \
    "$@"
