#!/bin/bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SKILL_ROOT

# Load canonical default snapshot ref (can be overridden via --snapshot-ref or ZEPHYR_SNAPSHOT_REF)
# shellcheck source=snapshot_defaults.sh
source "${SCRIPT_DIR}/snapshot_defaults.sh"
MODE="burnin"
BURNIN_ITERATIONS=5
WORK_ROOT=""
WITH_HF_REAL_WORKLOAD=0

usage() {
    cat <<'USAGE'
Usage:
  validate_hermetic_runtime_suite.sh [options]

Options:
  --snapshot-ref <ref>        Digest-pinned snapshot ref.
  --mode <mode>               full|burnin (default: burnin).
  --burnin-iterations <n>     Iteration count for burnin mode (default: 5).
  --work-root <path>          Root directory for isolated validation repo.
  --with-hf-real-workload     Run real HF inference workload on sygaldry/zephyr:hf.
USAGE
}

log() {
    echo "[zephyr-runtime-suite] $*" >&2
}

err() {
    log "ERROR: $*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

require_digest_ref() {
    local ref="$1"
    [[ -n "${ref}" ]] || err "snapshot ref is empty"
    [[ "${ref}" == *@sha256:* ]] || err "snapshot ref must include @sha256: digest"
    local digest
    digest="${ref##*@sha256:}"
    [[ "${digest}" =~ ^[a-f0-9]{64}$ ]] || err "invalid snapshot digest: ${digest}"
}

wait_for_job() {
    local jobctl="$1"
    local project_id="$2"
    local job_name="$3"
    local timeout_s="${4:-1800}"
    local elapsed=0
    local projects_root
    projects_root="${ZEPHYR_PROJECTS_ROOT:-/mnt/data_infra/zephyr_container_infra/projects}"

    while true; do
        local status_line="PENDING"
        local latest_status
        latest_status="$(ls -t "${projects_root}/${project_id}/outputs/.run-metadata"/*/"${job_name}.status" 2>/dev/null | head -n 1 || true)"
        if [[ -n "${latest_status}" && -f "${latest_status}" ]]; then
            status_line="$(tail -n 1 "${latest_status}" 2>/dev/null || echo PENDING)"
        fi

        if [[ "${status_line}" == DONE* ]]; then
            log "job done project=${project_id} job=${job_name}"
            return 0
        fi
        if [[ "${status_line}" == FAILED* ]]; then
            "${jobctl}" tail --project-id "${project_id}" --job "${job_name}" --lines 80 || true
            err "job failed project=${project_id} job=${job_name} status='${status_line}'"
        fi

        sleep 5
        elapsed=$((elapsed + 5))
        if [[ ${elapsed} -ge ${timeout_s} ]]; then
            "${jobctl}" health --project-id "${project_id}" --job "${job_name}" || true
            "${jobctl}" tail --project-id "${project_id}" --job "${job_name}" --lines 80 || true
            err "job timed out project=${project_id} job=${job_name}"
        fi
    done
}

run_and_wait() {
    local jobctl="$1"
    local project_id="$2"
    local job_name="$3"
    local command_text="$4"

    "${jobctl}" run --project-id "${project_id}" --job "${job_name}" -- "${command_text}" >/dev/null
    wait_for_job "${jobctl}" "${project_id}" "${job_name}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --snapshot-ref)
            SNAPSHOT_REF="${2:-}"
            shift 2
            ;;
        --mode)
            MODE="${2:-}"
            shift 2
            ;;
        --burnin-iterations)
            BURNIN_ITERATIONS="${2:-}"
            shift 2
            ;;
        --work-root)
            WORK_ROOT="${2:-}"
            shift 2
            ;;
        --with-hf-real-workload)
            WITH_HF_REAL_WORKLOAD=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            err "Unknown argument: $1"
            ;;
    esac
done

case "${MODE}" in
    full|burnin)
        ;;
    *)
        err "--mode must be full|burnin"
        ;;
esac

require_cmd bash
require_cmd docker
require_cmd git
require_cmd python3
require_cmd nvidia-smi

docker info >/dev/null 2>&1 || err "docker daemon unavailable"
docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"' || err "nvidia runtime not found in docker info"
nvidia-smi -L >/dev/null 2>&1 || err "nvidia-smi failed"
gpu_count="$(nvidia-smi -L | wc -l | tr -d ' ')"
[[ "${gpu_count}" -ge 2 ]] || err "Need at least 2 GPUs for NCCL/JAX checks"

require_digest_ref "${SNAPSHOT_REF}"

if [[ -z "${WORK_ROOT}" ]]; then
    WORK_ROOT="$(mktemp -d)"
else
    mkdir -p "${WORK_ROOT}"
    WORK_ROOT="$(realpath "${WORK_ROOT}")"
fi
readonly WORK_ROOT

TARGET_REPO="${WORK_ROOT}/hermetic-zephyr-validation"
mkdir -p "${TARGET_REPO}"
git -C "${TARGET_REPO}" init >/dev/null

log "work_root=${WORK_ROOT}"
log "target_repo=${TARGET_REPO}"
log "snapshot_ref=${SNAPSHOT_REF}"

"${SKILL_ROOT}/scripts/zephyr_vendor_infra.sh" install \
    --target-repo "${TARGET_REPO}" \
    --snapshot-ref "${SNAPSHOT_REF}" \
    --image-mode auto \
    --project-id "zephyr-hermetic-a" \
    --force

"${SKILL_ROOT}/scripts/zephyr_vendor_infra.sh" check \
    --target-repo "${TARGET_REPO}"

"${SKILL_ROOT}/scripts/zephyr_mlsys_vendor.sh" install \
    --target-repo "${TARGET_REPO}" \
    --snapshot-ref "${SNAPSHOT_REF}" \
    --force

KIT_DIR="${TARGET_REPO}/.sygal""dry/zephyr"
REPOCTL="${KIT_DIR}/bin/repoctl"
JOBCTL="${KIT_DIR}/bin/jobctl"
readonly KIT_DIR REPOCTL JOBCTL

[[ -x "${REPOCTL}" ]] || err "repoctl not found"
[[ -x "${JOBCTL}" ]] || err "jobctl not found"

cd "${TARGET_REPO}"

"${REPOCTL}" config show --repo "${TARGET_REPO}" >/dev/null
"${REPOCTL}" verify image --repo "${TARGET_REPO}" --skip-spack >/dev/null
"${REPOCTL}" verify spack --repo "${TARGET_REPO}" >/dev/null

mkdir -p "${TARGET_REPO}/zephyr_validation/workloads"
cp -a "${SKILL_ROOT}/scripts/workloads/." "${TARGET_REPO}/zephyr_validation/workloads/"

work_dir_in_container="/work""space/zephyr_validation/workloads"

iterations=1
if [[ "${MODE}" == "burnin" ]]; then
    iterations="${BURNIN_ITERATIONS}"
fi

run_tag="suite-$(date +%Y%m%d%H%M%S)-$$"

for i in $(seq 1 "${iterations}"); do
    log "iteration ${i}/${iterations}"
    proj_a="zephyr-burnin-a-${run_tag}-${i}"
    proj_b="zephyr-burnin-b-${run_tag}-${i}"
    job_concurrent_a="concurrent-a-${run_tag}-${i}"
    job_concurrent_b="concurrent-b-${run_tag}-${i}"
    job_torch="torch-nccl-${run_tag}-${i}"
    job_jax="jax-train-${run_tag}-${i}"
    job_llvm="llvm-${run_tag}-${i}"
    job_cuda="cuda-kernel-${run_tag}-${i}"

    "${JOBCTL}" run --project-id "${proj_a}" --job "${job_concurrent_a}" -- "python3 -c 'print(\"concurrent-a\")'" >/dev/null
    "${JOBCTL}" run --project-id "${proj_b}" --job "${job_concurrent_b}" -- "python3 -c 'print(\"concurrent-b\")'" >/dev/null
    wait_for_job "${JOBCTL}" "${proj_a}" "${job_concurrent_a}" 300
    wait_for_job "${JOBCTL}" "${proj_b}" "${job_concurrent_b}" 300

    run_and_wait "${JOBCTL}" "${proj_a}" "${job_torch}" \
        "torchrun --standalone --nproc_per_node=2 ${work_dir_in_container}/pytorch_nccl_train.py"

    run_and_wait "${JOBCTL}" "${proj_a}" "${job_jax}" \
        "python3 ${work_dir_in_container}/jax_multi_gpu_train.py"

    run_and_wait "${JOBCTL}" "${proj_b}" "${job_llvm}" \
        "python3 ${work_dir_in_container}/llvm_passes_check.py"

    run_and_wait "${JOBCTL}" "${proj_b}" "${job_cuda}" \
        "python3 ${work_dir_in_container}/cuda_kernel_check.py"
done

"${TARGET_REPO}/.zephyr-mlsys/bin/launch-mlsys.sh" hf-transformers --no-validate >/dev/null
"${TARGET_REPO}/.zephyr-mlsys/bin/launch-mlsys.sh" vllm --no-validate >/dev/null

if [[ "${WITH_HF_REAL_WORKLOAD}" -eq 1 ]]; then
    log "running optional HF real workload"
    "${SKILL_ROOT}/scripts/run_hf_real_workload.sh" \
        --work-root "${WORK_ROOT}/hf-real" \
        --split "test[:2000]" \
        --batch-size 64 \
        --max-length 256
fi

REPORT_PATH="${WORK_ROOT}/runtime-suite-report.json"
python3 - "${REPORT_PATH}" "${WORK_ROOT}" "${TARGET_REPO}" "${SNAPSHOT_REF}" "${MODE}" "${iterations}" "${gpu_count}" <<'PY'
import json
import os
import sys

report_path, work_root, target_repo, snapshot_ref, mode, iterations, gpu_count = sys.argv[1:]
payload = {
    "suite": "zephyr-hermetic-runtime",
    "status": "PASS",
    "work_root": work_root,
    "target_repo": target_repo,
    "snapshot_ref": snapshot_ref,
    "mode": mode,
    "iterations": int(iterations),
    "gpu_count": int(gpu_count),
    "timestamp_utc": os.popen("date -u +%Y-%m-%dT%H:%M:%SZ").read().strip(),
}
with open(report_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

log "PASS: report=${REPORT_PATH}"
