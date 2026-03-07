#!/usr/bin/env bash
# tools/agentic/sail_cron.sh — Unattended cron wrapper for SAIL.

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly ROOT_DIR
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
readonly CONFIG_FILE

DEFAULT_ENV_FILE="/mnt/data_infra/zephyr_container_infra/sygaldry/config/sail-cron.env"
readonly DEFAULT_ENV_FILE
ENV_FILE="${SAIL_CRON_ENV_FILE:-${DEFAULT_ENV_FILE}}"
readonly ENV_FILE

if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
fi

RUNTIME_ROOT="${SAIL_RUNTIME_ROOT:-/mnt/data_infra/zephyr_container_infra/sygaldry/logs/sail}"
RETENTION_DAYS="${SAIL_RETENTION_DAYS:-30}"
TEMPORAL_ADDRESS="${TEMPORAL_ADDRESS:-localhost:7233}"
TEMPORAL_NAMESPACE="${TEMPORAL_NAMESPACE:-default}"
TEMPORAL_TASK_QUEUE="${TEMPORAL_TASK_QUEUE:-orchestration}"

RUNS_DIR="${RUNTIME_ROOT}/runs"
INFRA_DIR="${RUNTIME_ROOT}/infra"
STATUS_FILE="${RUNTIME_ROOT}/last_status.json"
LOCK_FILE="${RUNTIME_ROOT}/cron.lock"
WORKER_PID_FILE="${INFRA_DIR}/worker.pid"
WORKER_SHA_FILE="${INFRA_DIR}/worker.git_sha"
WORKER_LOG="${INFRA_DIR}/worker.log"
WORKER_TEMPORAL_LOG_DIR="${INFRA_DIR}/worker-temporal-logs"

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [sail-cron] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

_cfg_section() {
    local section="$1" key="$2" default="$3"
    local value
    value="$(
        awk -v target_section="${section}" -v target_key="${key}" '
            $0 ~ ("^" target_section ":") { in_section = 1; next }
            in_section && $0 ~ /^[^[:space:]]/ { in_section = 0 }
            in_section && $0 ~ ("^  " target_key ":") {
                sub(/^[^:]+:[[:space:]]*/, "", $0)
                sub(/[[:space:]]+#.*$/, "", $0)
                gsub(/"/, "", $0)
                gsub(/[[:space:]]+$/, "", $0)
                print
                exit
            }
        ' "${CONFIG_FILE}" 2>/dev/null || true
    )"
    echo "${value:-${default}}"
}

BASE_BRANCH="${SAIL_BASE_BRANCH:-$(_cfg_section repo base_branch main)}"
PLANNER_ENGINE="${SAIL_PLANNER_ENGINE:-$(_cfg_section planner engine local)}"
IMPLEMENTER_ENGINE="${SAIL_IMPLEMENTER_ENGINE:-$(_cfg_section implementer engine claude)}"

mkdir -p "${RUNS_DIR}" "${INFRA_DIR}" "${WORKER_TEMPORAL_LOG_DIR}"

write_status() {
    local status="$1" message="$2" run_id="${3:-}" primary_rc="${4:-}" selffix_rc="${5:-}" synthetic_count="${6:-0}"
    python3 - "$STATUS_FILE" "$status" "$message" "$run_id" "$primary_rc" "$selffix_rc" "$synthetic_count" <<'PY'
import datetime as dt
import json
import sys

path, status, message, run_id, primary_rc, selffix_rc, synthetic_count = sys.argv[1:8]
payload = {
    "status": status,
    "message": message,
    "runId": run_id,
    "primaryExitCode": primary_rc,
    "selfFixExitCode": selffix_rc,
    "syntheticIssueCount": int(synthetic_count or 0),
    "updatedAt": dt.datetime.utcnow().isoformat() + "Z",
}
with open(path, "w", encoding="utf-8") as file:
    json.dump(payload, file, indent=2, sort_keys=True)
    file.write("\n")
PY
}

require_cmd() {
    local name="$1"
    command -v "${name}" >/dev/null 2>&1 || die "required command not found: ${name}"
}

require_agent_cli() {
    local engine="$1"
    case "${engine}" in
        local)
            ;;
        claude|codex|cursor|echo)
            [[ "${engine}" == "echo" ]] || require_cmd "${engine}"
            ;;
        *)
            die "unsupported SAIL engine in cron wrapper: ${engine}"
            ;;
    esac
}

wait_for_temporal() {
    local host="${TEMPORAL_ADDRESS%%:*}"
    local port="${TEMPORAL_ADDRESS##*:}"
    local attempts=60
    while (( attempts > 0 )); do
        if nc -z "${host}" "${port}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        attempts=$((attempts - 1))
    done
    return 1
}

ensure_temporal_server() {
    if wait_for_temporal; then
        return 0
    fi

    local host="${TEMPORAL_ADDRESS%%:*}"
    if [[ "${host}" != "localhost" && "${host}" != "127.0.0.1" ]]; then
        die "Temporal address ${TEMPORAL_ADDRESS} is remote and not reachable"
    fi

    if command -v docker >/dev/null 2>&1; then
        log "Temporal not reachable; starting docker compose stack"
        (
            cd "${ROOT_DIR}/temporal"
            if docker compose version >/dev/null 2>&1; then
                docker compose up -d
            elif command -v docker-compose >/dev/null 2>&1; then
                docker-compose up -d
            else
                die "docker is installed but neither docker compose nor docker-compose is available"
            fi
        )
    elif command -v temporal >/dev/null 2>&1; then
        log "Temporal not reachable; starting Temporal dev server"
        nohup temporal server start-dev --ui-port 8233 >/tmp/sail-temporal-server.log 2>&1 &
    else
        die "Temporal is down and neither docker nor temporal CLI is available"
    fi

    wait_for_temporal || die "Temporal did not become ready at ${TEMPORAL_ADDRESS}"
}

restart_worker() {
    local head_sha="$1"
    if [[ -f "${WORKER_PID_FILE}" ]]; then
        local current_pid
        current_pid="$(cat "${WORKER_PID_FILE}" 2>/dev/null || true)"
        if [[ -n "${current_pid}" ]] && kill -0 "${current_pid}" >/dev/null 2>&1; then
            log "Stopping stale worker pid ${current_pid}"
            kill "${current_pid}" >/dev/null 2>&1 || true
            wait "${current_pid}" 2>/dev/null || true
        fi
    fi

    log "Starting managed Temporal worker"
    (
        exec 9>&-
        cd "${ROOT_DIR}/temporal"
        nohup env \
            TEMPORAL_ADDRESS="${TEMPORAL_ADDRESS}" \
            TEMPORAL_NAMESPACE="${TEMPORAL_NAMESPACE}" \
            TEMPORAL_TASK_QUEUE="${TEMPORAL_TASK_QUEUE}" \
            TEMPORAL_LOG_DIR="${WORKER_TEMPORAL_LOG_DIR}" \
            go run ./cmd/worker >>"${WORKER_LOG}" 2>&1 &
        echo $! > "${WORKER_PID_FILE}"
    )
    echo "${head_sha}" > "${WORKER_SHA_FILE}"
    sleep 1

    local worker_pid
    worker_pid="$(cat "${WORKER_PID_FILE}")"
    if ! kill -0 "${worker_pid}" >/dev/null 2>&1; then
        die "worker failed to start; see ${WORKER_LOG}"
    fi
}

ensure_worker() {
    local head_sha="$1"
    local restart=false

    if [[ ! -f "${WORKER_PID_FILE}" || ! -f "${WORKER_SHA_FILE}" ]]; then
        restart=true
    else
        local worker_pid worker_sha
        worker_pid="$(cat "${WORKER_PID_FILE}" 2>/dev/null || true)"
        worker_sha="$(cat "${WORKER_SHA_FILE}" 2>/dev/null || true)"
        if [[ -z "${worker_pid}" ]] || ! kill -0 "${worker_pid}" >/dev/null 2>&1; then
            restart=true
        elif [[ "${worker_sha}" != "${head_sha}" ]]; then
            restart=true
        fi
    fi

    if [[ "${restart}" == "true" ]]; then
        restart_worker "${head_sha}"
    fi
}

require_clean_main_checkout() {
    local current_branch
    current_branch="$(git -C "${ROOT_DIR}" branch --show-current)"
    if [[ "${current_branch}" != "${BASE_BRANCH}" ]]; then
        write_status "failed" "refusing to run outside ${BASE_BRANCH}" "" "" "" 0
        die "current branch is ${current_branch}; expected ${BASE_BRANCH}"
    fi

    if [[ -n "$(git -C "${ROOT_DIR}" status --short)" ]]; then
        write_status "failed" "refusing to run on dirty worktree" "" "" "" 0
        die "working tree is dirty; refusing unattended SAIL run"
    fi
}

sync_main() {
    log "Fetching and fast-forwarding ${BASE_BRANCH}"
    git -C "${ROOT_DIR}" fetch origin "${BASE_BRANCH}"
    git -C "${ROOT_DIR}" pull --ff-only origin "${BASE_BRANCH}"
}

prune_old_runs() {
    if [[ "${RETENTION_DAYS}" -lt 0 ]]; then
        return 0
    fi
    find "${RUNS_DIR}" -mindepth 1 -maxdepth 1 -type d -mtime +"${RETENTION_DAYS}" -exec rm -rf {} +
}

count_json_items() {
    local path="$1"
    python3 - "$path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print(0)
    raise SystemExit(0)
data = json.loads(path.read_text(encoding="utf-8"))
print(len(data) if isinstance(data, list) else 0)
PY
}

main() {
    require_cmd git
    require_cmd go
    require_cmd python3
    require_cmd nc
    require_cmd gh
    if [[ "${PLANNER_ENGINE}" != "local" ]]; then
        require_agent_cli "${PLANNER_ENGINE}"
    fi
    require_agent_cli "${IMPLEMENTER_ENGINE}"
    gh auth status >/dev/null 2>&1 || die "gh CLI is not authenticated"

    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        log "another sail_cron instance is already running; exiting"
        write_status "skipped" "lock busy" "" "" "" 0
        exit 0
    fi

    require_clean_main_checkout
    sync_main

    local head_sha
    head_sha="$(git -C "${ROOT_DIR}" rev-parse --short HEAD)"

    ensure_temporal_server
    ensure_worker "${head_sha}"

    local run_id run_dir primary_dir analysis_dir selffix_dir
    run_id="sailcron-$(date +'%Y%m%d-%H%M%S')-${head_sha}"
    run_dir="${RUNS_DIR}/${run_id}"
    primary_dir="${run_dir}/primary"
    analysis_dir="${run_dir}/analysis"
    selffix_dir="${run_dir}/selffix"
    mkdir -p "${run_dir}"

    log "Launching primary SAIL run ${run_id}"
    local primary_rc=0
    set +e
    "${SCRIPT_DIR}/run_improvement_loop.sh" \
        --run-id "${run_id}-primary" \
        --artifacts-dir "${primary_dir}"
    primary_rc=$?
    set -e
    if [[ ${primary_rc} -ne 0 ]]; then
        log "Primary SAIL run exited with ${primary_rc}"
    fi

    log "Analyzing primary run ${run_id}"
    python3 "${SCRIPT_DIR}/analyze_sail_run.py" --run-dir "${primary_dir}" --output-dir "${analysis_dir}"

    local synthetic_issues_file="${analysis_dir}/self_improvement_issues.json"
    local synthetic_count
    synthetic_count="$(count_json_items "${synthetic_issues_file}")"

    local selffix_rc=0
    if [[ "${synthetic_count}" -gt 0 ]]; then
        log "Launching self-improvement pass with ${synthetic_count} synthetic issue(s)"
        set +e
        SAIL_RUN_KIND=self_improvement "${SCRIPT_DIR}/run_improvement_loop.sh" \
            --run-id "${run_id}-selffix" \
            --artifacts-dir "${selffix_dir}" \
            --issues-file "${synthetic_issues_file}"
        selffix_rc=$?
        set -e
        if [[ ${selffix_rc} -ne 0 ]]; then
            log "Self-improvement pass exited with ${selffix_rc}"
        fi
    else
        log "No synthetic self-improvement issues emitted"
    fi

    prune_old_runs

    if [[ ${primary_rc} -eq 0 && ${selffix_rc} -eq 0 ]]; then
        write_status "success" "cron run completed" "${run_id}" "${primary_rc}" "${selffix_rc}" "${synthetic_count}"
        return 0
    fi
    write_status "failed" "cron run completed with failures" "${run_id}" "${primary_rc}" "${selffix_rc}" "${synthetic_count}"
    return 1
}

main "$@"
