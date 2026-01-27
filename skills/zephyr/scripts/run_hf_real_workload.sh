#!/bin/bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly SKILL_ROOT

HF_IMAGE="sygaldry/zephyr:hf"
# Load canonical default snapshot ref (can be overridden via --snapshot-ref or ZEPHYR_SNAPSHOT_REF)
# shellcheck source=snapshot_defaults.sh
source "${SCRIPT_DIR}/snapshot_defaults.sh"
WORK_ROOT=""
MODEL_ID="distilbert-base-uncased-finetuned-sst-2-english"
DATASET_ID="ag_news"
DATASET_CONFIG=""
SPLIT="test[:5000]"
TEXT_COLUMN="text"
BATCH_SIZE=64
MAX_LENGTH=256

usage() {
    cat <<'USAGE'
Usage:
  run_hf_real_workload.sh [options]

Options:
  --image <ref>             Runtime image tag/ref (default: sygaldry/zephyr:hf)
  --snapshot-ref <ref>      Digest-pinned base image ref for vendored infra
  --work-root <path>        Root directory for isolated validation repo
  --model-id <id>           HF model id
  --dataset-id <id>         HF dataset id
  --dataset-config <name>   Optional HF dataset config
  --split <split>           Dataset split (default: test[:5000])
  --text-column <col>       Dataset text column (default: text)
  --batch-size <n>          Inference batch size (default: 64)
  --max-length <n>          Token max length (default: 256)
USAGE
}

log() {
    echo "[hf-real-workload] $*" >&2
}

err() {
    log "ERROR: $*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || err "Missing command: $1"
}

wait_for_job() {
    local jobctl="$1"
    local project_id="$2"
    local job_name="$3"
    local timeout_s="${4:-5400}"
    local elapsed=0
    local projects_root
    projects_root="${ZEPHYR_PROJECTS_ROOT:-/mnt/data_infra/zephyr_container_infra/projects}"

    while true; do
        local status_line="PENDING"
        local latest_status
        local run_id=""
        latest_status="$(ls -t "${projects_root}/${project_id}/outputs/.run-metadata"/*/"${job_name}.status" 2>/dev/null | head -n 1 || true)"
        if [[ -n "${latest_status}" && -f "${latest_status}" ]]; then
            status_line="$(tail -n 1 "${latest_status}" 2>/dev/null || echo PENDING)"
            run_id="$(basename "$(dirname "${latest_status}")")"
        fi

        if [[ "${status_line}" == DONE* ]]; then
            log "job done project=${project_id} job=${job_name}"
            echo "${run_id}"
            return 0
        fi
        if [[ "${status_line}" == FAILED* ]]; then
            if [[ -n "${run_id}" ]]; then
                "${jobctl}" tail --project-id "${project_id}" --run-id "${run_id}" --job "${job_name}" --lines 100 || true
            else
                "${jobctl}" tail --project-id "${project_id}" --job "${job_name}" --lines 100 || true
            fi
            err "job failed project=${project_id} job=${job_name} status='${status_line}'"
        fi

        sleep 5
        elapsed=$((elapsed + 5))
        if [[ ${elapsed} -ge ${timeout_s} ]]; then
            if [[ -n "${run_id}" ]]; then
                "${jobctl}" health --project-id "${project_id}" --run-id "${run_id}" --job "${job_name}" || true
                "${jobctl}" tail --project-id "${project_id}" --run-id "${run_id}" --job "${job_name}" --lines 100 || true
            else
                "${jobctl}" health --project-id "${project_id}" --job "${job_name}" || true
                "${jobctl}" tail --project-id "${project_id}" --job "${job_name}" --lines 100 || true
            fi
            err "job timed out project=${project_id} job=${job_name}"
        fi
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            HF_IMAGE="${2:-}"
            shift 2
            ;;
        --snapshot-ref)
            SNAPSHOT_REF="${2:-}"
            shift 2
            ;;
        --work-root)
            WORK_ROOT="${2:-}"
            shift 2
            ;;
        --model-id)
            MODEL_ID="${2:-}"
            shift 2
            ;;
        --dataset-id)
            DATASET_ID="${2:-}"
            shift 2
            ;;
        --dataset-config)
            DATASET_CONFIG="${2:-}"
            shift 2
            ;;
        --split)
            SPLIT="${2:-}"
            shift 2
            ;;
        --text-column)
            TEXT_COLUMN="${2:-}"
            shift 2
            ;;
        --batch-size)
            BATCH_SIZE="${2:-}"
            shift 2
            ;;
        --max-length)
            MAX_LENGTH="${2:-}"
            shift 2
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

require_cmd docker
require_cmd git
require_cmd python3
require_cmd nvidia-smi

docker info >/dev/null 2>&1 || err "docker daemon unavailable"
docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"' || err "nvidia runtime not found in docker info"
nvidia-smi -L >/dev/null 2>&1 || err "nvidia-smi failed"

docker image inspect "${HF_IMAGE}" >/dev/null 2>&1 || err "Runtime image not found locally: ${HF_IMAGE}"

if [[ -z "${WORK_ROOT}" ]]; then
    WORK_ROOT="$(mktemp -d)"
else
    mkdir -p "${WORK_ROOT}"
    WORK_ROOT="$(realpath "${WORK_ROOT}")"
fi
readonly WORK_ROOT

TARGET_REPO="${WORK_ROOT}/hf-real-workload-repo"
mkdir -p "${TARGET_REPO}"
git -C "${TARGET_REPO}" init >/dev/null

log "work_root=${WORK_ROOT}"
log "target_repo=${TARGET_REPO}"
log "runtime_image=${HF_IMAGE}"
log "snapshot_ref=${SNAPSHOT_REF}"

"${SKILL_ROOT}/scripts/zephyr_vendor_infra.sh" install \
    --target-repo "${TARGET_REPO}" \
    --snapshot-ref "${SNAPSHOT_REF}" \
    --base-image-ref "${SNAPSHOT_REF}" \
    --runtime-image "${HF_IMAGE}" \
    --image-mode derived \
    --project-id "zephyr-hf-real" \
    --force

"${SKILL_ROOT}/scripts/zephyr_vendor_infra.sh" check \
    --target-repo "${TARGET_REPO}"

KIT_DIR="${TARGET_REPO}/.sygal""dry/zephyr"
REPOCTL="${KIT_DIR}/bin/repoctl"
JOBCTL="${KIT_DIR}/bin/jobctl"
readonly KIT_DIR REPOCTL JOBCTL
[[ -x "${REPOCTL}" ]] || err "repoctl not found"
[[ -x "${JOBCTL}" ]] || err "jobctl not found"

mkdir -p "${TARGET_REPO}/zephyr_validation/workloads" "${TARGET_REPO}/zephyr_validation/reports"
cp -a "${SKILL_ROOT}/scripts/workloads/hf_inference_real_dataset.py" "${TARGET_REPO}/zephyr_validation/workloads/"

"${REPOCTL}" config show --repo "${TARGET_REPO}" >/dev/null
# jobctl/launch_container binds host PWD to /workspace in-container.
# Run from target repo so workload files copied there are visible at /workspace/*.
cd "${TARGET_REPO}"

run_tag="hf-real-$(date +%Y%m%d%H%M%S)-$$"
project_id="zephyr-hf-real-${run_tag}"
job_name="hf-inference-real"
work_script="/workspace/zephyr_validation/workloads/hf_inference_real_dataset.py"
report_path="/workspace/zephyr_validation/reports/hf_inference_report.json"

dataset_cfg_arg=""
if [[ -n "${DATASET_CONFIG}" ]]; then
    dataset_cfg_arg=" --dataset-config ${DATASET_CONFIG}"
fi

bootstrap_cmd="python3 -c 'import datasets, soundfile' >/dev/null 2>&1 || uv pip install --python \"\$(command -v python3)\" datasets soundfile"
command_text="${bootstrap_cmd} && python3 ${work_script} --model-id ${MODEL_ID} --dataset-id ${DATASET_ID}${dataset_cfg_arg} --split \"${SPLIT}\" --text-column ${TEXT_COLUMN} --batch-size ${BATCH_SIZE} --max-length ${MAX_LENGTH} --report-path ${report_path}"

log "launching job project_id=${project_id} job_name=${job_name}"
"${JOBCTL}" run --project-id "${project_id}" --job "${job_name}" -- "${command_text}" >/dev/null
run_id="$(wait_for_job "${JOBCTL}" "${project_id}" "${job_name}" 7200)"

if [[ -n "${run_id}" ]]; then
    "${JOBCTL}" tail --project-id "${project_id}" --run-id "${run_id}" --job "${job_name}" --lines 120 || true
else
    "${JOBCTL}" tail --project-id "${project_id}" --job "${job_name}" --lines 120 || true
fi

host_report="${TARGET_REPO}/zephyr_validation/reports/hf_inference_report.json"
[[ -f "${host_report}" ]] || err "Expected report missing: ${host_report}"

python3 - "${host_report}" <<'PY'
import json
import sys

report_path = sys.argv[1]
with open(report_path, 'r', encoding='utf-8') as f:
    data = json.load(f)
required = [
    'suite', 'status', 'model_id', 'dataset_id', 'split',
    'throughput', 'latency_ms', 'cuda_memory_bytes', 'timings'
]
for key in required:
    if key not in data:
        raise SystemExit(f"missing key: {key}")
if data.get('status') != 'PASS':
    raise SystemExit(f"status not PASS: {data.get('status')}")
if data['throughput'].get('samples_per_second', 0) <= 0:
    raise SystemExit('non-positive throughput')
if data['cuda_memory_bytes'].get('max_allocated', 0) <= 0:
    raise SystemExit('non-positive cuda memory usage')
print(json.dumps({
    'status': data['status'],
    'samples_per_second': data['throughput']['samples_per_second'],
    'p95_ms': data['latency_ms']['p95'],
    'max_cuda_mem_gb': round(data['cuda_memory_bytes']['max_allocated'] / (1024**3), 3),
}, sort_keys=True))
PY

log "PASS report=${host_report}"
