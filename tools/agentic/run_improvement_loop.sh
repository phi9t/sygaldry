#!/usr/bin/env bash
# tools/agentic/run_improvement_loop.sh — Outer loop for SAIL.
#
# Discovers issues, then for each issue (up to max_tasks_per_run) runs the
# improvement_loop.yaml Temporal pipeline.  Retries on validate failure up to
# max_retries_per_task times using the retry prompt.
#
# Usage:
#   ./tools/agentic/run_improvement_loop.sh [--dry-run] [--repo-dir <path>]
#
# Environment overrides (also readable from config.yaml):
#   SAIL_PLANNER_ENGINE     SAIL_PLANNER_MODEL
#   SAIL_IMPLEMENTER_ENGINE SAIL_IMPLEMENTER_MODEL
#   SAIL_MAX_TASKS          SAIL_MAX_RETRIES    SAIL_MIN_PRIORITY
#   SAIL_MAX_PARALLEL       (default 1 = sequential)
#   TEMPORAL_ADDRESS        TEMPORAL_NAMESPACE  TEMPORAL_TASK_QUEUE

set -eu -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

REPO_DIR="${SCRIPT_DIR}/../.."
REPO_DIR="$(cd "${REPO_DIR}" && pwd)"

CONFIG="${SCRIPT_DIR}/config.yaml"
TEMPORAL_DIR="${REPO_DIR}/temporal"
PLAN_FILE="${SCRIPT_DIR}/improvement_loop.yaml"
DISCOVER="${SCRIPT_DIR}/discover_issues.py"

# Tracks issues already attempted across loop invocations (not committed).
ATTEMPTED_FILE="${REPO_DIR}/.agentic/attempted.jsonl"

DRY_RUN=false

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [SAIL:${BASH_LINENO[0]}] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true; shift ;;
        --repo-dir)  REPO_DIR="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

# ── Read config.yaml (simple grep-based extraction) ──────────────────────────
_cfg() {
    # Usage: _cfg <key> <default>
    # Reads `key: value` from config.yaml; falls back to <default>.
    local key="$1" default="$2"
    local val
    val="$(grep -E "^  ${key}:" "${CONFIG}" 2>/dev/null \
           | head -1 \
           | sed 's/.*: *//' \
           | tr -d '"' || true)"
    echo "${val:-${default}}"
}

PLANNER_ENGINE="${SAIL_PLANNER_ENGINE:-$(_cfg engine claude)}"
PLANNER_MODEL="${SAIL_PLANNER_MODEL:-$(_cfg model claude-opus-4-6)}"
IMPLEMENTER_ENGINE="${SAIL_IMPLEMENTER_ENGINE:-claude}"
IMPLEMENTER_MODEL="${SAIL_IMPLEMENTER_MODEL:-claude-sonnet-4-6}"
MAX_TASKS="${SAIL_MAX_TASKS:-$(_cfg max_tasks_per_run 3)}"
MAX_RETRIES="${SAIL_MAX_RETRIES:-$(_cfg max_retries_per_task 2)}"
MIN_PRIORITY="${SAIL_MIN_PRIORITY:-$(_cfg min_priority 2)}"
MAX_PARALLEL="${SAIL_MAX_PARALLEL:-$(_cfg max_parallel 1)}"

TEMPORAL_ADDRESS="${TEMPORAL_ADDRESS:-localhost:7233}"
TEMPORAL_NAMESPACE="${TEMPORAL_NAMESPACE:-default}"
TEMPORAL_TASK_QUEUE="${TEMPORAL_TASK_QUEUE:-orchestration}"

log "SAIL starting (dry_run=${DRY_RUN}, max_tasks=${MAX_TASKS}, max_retries=${MAX_RETRIES}, max_parallel=${MAX_PARALLEL})"
log "planner: engine=${PLANNER_ENGINE} model=${PLANNER_MODEL}"
log "implementer: engine=${IMPLEMENTER_ENGINE} model=${IMPLEMENTER_MODEL}"

# ── Temporal preflight check ──────────────────────────────────────────────────
if [[ "${DRY_RUN}" != "true" ]]; then
    TEMPORAL_HOST="${TEMPORAL_ADDRESS%%:*}"
    TEMPORAL_PORT="${TEMPORAL_ADDRESS##*:}"
    if ! nc -z "${TEMPORAL_HOST}" "${TEMPORAL_PORT}" 2>/dev/null; then
        die "Temporal server not reachable at ${TEMPORAL_ADDRESS}; start the worker first (cd temporal && ./scripts/start-temporal.sh)"
    fi
    log "Temporal server reachable at ${TEMPORAL_ADDRESS}"
fi

# ── Initialise deduplication state ───────────────────────────────────────────
mkdir -p "$(dirname "${ATTEMPTED_FILE}")"
touch "${ATTEMPTED_FILE}"

_is_already_handled() {
    local issue_id="$1"
    # Return 0 (true) if last recorded status for this issue is pr_created or skipped.
    if grep -q "\"${issue_id}\"" "${ATTEMPTED_FILE}" 2>/dev/null; then
        local last_status
        last_status="$(grep "\"${issue_id}\"" "${ATTEMPTED_FILE}" \
            | python3 -c "import json,sys; entries=list(map(json.loads,sys.stdin)); print(entries[-1].get('status',''))" 2>/dev/null || true)"
        if [[ "${last_status}" == "pr_created" || "${last_status}" == "skipped" ]]; then
            return 0
        fi
    fi
    return 1
}

_record_attempt() {
    local issue_id="$1" status="$2" branch="$3" pr_url="${4:-}"
    python3 -c "
import json, sys
print(json.dumps({'issue_id': sys.argv[1], 'status': sys.argv[2], 'branch': sys.argv[3], 'pr_url': sys.argv[4], 'timestamp': __import__('datetime').datetime.utcnow().isoformat()}))
" "${issue_id}" "${status}" "${branch}" "${pr_url}" >> "${ATTEMPTED_FILE}" || true
}

# ── Discover issues ───────────────────────────────────────────────────────────
ISSUES_JSON="$(python3 "${DISCOVER}" \
    --repo-dir "${REPO_DIR}" \
    --min-priority "${MIN_PRIORITY}" \
    --max-per-type 20)"

TOTAL="$(echo "${ISSUES_JSON}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
log "discovered ${TOTAL} issues (min_priority<=${MIN_PRIORITY})"

if [[ "${TOTAL}" -eq 0 ]]; then
    log "no issues to fix; exiting"
    exit 0
fi

# ── Per-issue pipeline runner ─────────────────────────────────────────────────

_run_issue() {
    local ISSUE_JSON="$1"

    local ISSUE_ID ISSUE_TITLE TIMESTAMP SLUG BRANCH_NAME WORKFLOW_ID
    ISSUE_ID="$(echo "${ISSUE_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")"
    ISSUE_TITLE="$(echo "${ISSUE_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'][:60])")"
    TIMESTAMP="$(date +'%Y%m%d-%H%M%S')"
    SLUG="$(echo "${ISSUE_ID}" | tr '/' '-' | tr '[:upper:]' '[:lower:]')"
    BRANCH_NAME="agentic/${TIMESTAMP}-${SLUG}"
    WORKFLOW_ID="sail-${TIMESTAMP}-${SLUG}"

    log "── issue ${ISSUE_ID}: ${ISSUE_TITLE}"
    log "   branch: ${BRANCH_NAME}"

    # ── Deduplication check ───────────────────────────────────────────────────
    if _is_already_handled "${ISSUE_ID}"; then
        log "   skipping ${ISSUE_ID}: already handled in a previous run"
        return 0
    fi

    # Check if a matching branch already exists on origin.
    if git -C "${REPO_DIR}" ls-remote --heads origin "agentic/*-${SLUG}" 2>/dev/null | grep -q .; then
        log "   skipping ${ISSUE_ID}: branch agentic/*-${SLUG} already exists on origin"
        _record_attempt "${ISSUE_ID}" "skipped" "${BRANCH_NAME}"
        return 0
    fi

    local ATTEMPT=0 SUCCESS=false

    while [[ $((ATTEMPT)) -le $((MAX_RETRIES)) ]]; do
        if [[ "${DRY_RUN}" == "true" ]]; then
            log "   [dry-run] would run orchestrate for issue ${ISSUE_ID} (attempt $((ATTEMPT+1)))"
            SUCCESS=true
            break
        fi

        log "   attempt $((ATTEMPT+1))/$((MAX_RETRIES+1))"

        # On retry, switch to the retry prompt.
        local PROMPT_FILE="${SCRIPT_DIR}/prompts/planner.md"
        if [[ $((ATTEMPT)) -gt 0 ]]; then
            PROMPT_FILE="${SCRIPT_DIR}/prompts/retry.md"
        fi

        # Per-run log dir so we can find the validate stderr after failure.
        local LOG_DIR="/tmp/sail-logs/${WORKFLOW_ID}-a${ATTEMPT}"
        mkdir -p "${LOG_DIR}"

        # failure_context_file is populated on previous-attempt failure; empty on first run.
        local FAILURE_CONTEXT_FILE="/tmp/sail-${ISSUE_ID}-failure.txt"
        local FAILURE_CTX_FLAG=""
        if [[ $((ATTEMPT)) -gt 0 && -f "${FAILURE_CONTEXT_FILE}" ]]; then
            FAILURE_CTX_FLAG="${FAILURE_CONTEXT_FILE}"
        fi

        local EXIT_CODE=0
        (
            cd "${TEMPORAL_DIR}"
            go run ./cmd/orchestrate run \
                -plan "${PLAN_FILE}" \
                -log-dir "${LOG_DIR}" \
                -address "${TEMPORAL_ADDRESS}" \
                -namespace "${TEMPORAL_NAMESPACE}" \
                -task-queue "${TEMPORAL_TASK_QUEUE}" \
                -workflow-id "${WORKFLOW_ID}-a${ATTEMPT}" \
                -set "issue_json=${ISSUE_JSON}" \
                -set "issue_title=${ISSUE_TITLE}" \
                -set "branch_name=${BRANCH_NAME}" \
                -set "repo_dir=${REPO_DIR}" \
                -set "workflow_id=${WORKFLOW_ID}-a${ATTEMPT}" \
                -set "planner_engine=${PLANNER_ENGINE}" \
                -set "planner_model=${PLANNER_MODEL}" \
                -set "planner_prompt_file=${PROMPT_FILE}" \
                -set "implementer_engine=${IMPLEMENTER_ENGINE}" \
                -set "implementer_model=${IMPLEMENTER_MODEL}" \
                -set "failure_context_file=${FAILURE_CTX_FLAG}"
        ) || EXIT_CODE=$?

        if [[ $((EXIT_CODE)) -eq 0 ]]; then
            SUCCESS=true
            break
        fi

        log "   attempt $((ATTEMPT+1)) failed (exit=${EXIT_CODE})"

        # Capture validation failure context for the next retry prompt.
        local VALIDATE_STDERR
        VALIDATE_STDERR="$(find "${LOG_DIR}" -name "*validate*stderr*" -type f 2>/dev/null | head -1)"
        if [[ -n "${VALIDATE_STDERR}" && -f "${VALIDATE_STDERR}" ]]; then
            tail -100 "${VALIDATE_STDERR}" > "${FAILURE_CONTEXT_FILE}"
            log "   validation failure captured to ${FAILURE_CONTEXT_FILE}"
        else
            echo "No validation stderr captured for ${WORKFLOW_ID}-a${ATTEMPT}." > "${FAILURE_CONTEXT_FILE}"
        fi

        ATTEMPT=$((ATTEMPT+1))
    done

    if [[ "${SUCCESS}" == "true" ]]; then
        log "   ✓ issue ${ISSUE_ID} handled"
        _record_attempt "${ISSUE_ID}" "pr_created" "${BRANCH_NAME}"
        return 0
    else
        log "   ✗ issue ${ISSUE_ID} exhausted retries"
        _record_attempt "${ISSUE_ID}" "failed" "${BRANCH_NAME}"
        return 1
    fi
}

# ── Run pipeline for each issue (with optional parallelism) ───────────────────
PROCESSED=0
SUCCEEDED=0
FAILED=0

declare -a BG_PIDS=()
declare -a BG_ISSUES=()

_wait_all_bg() {
    local pid
    for i in "${!BG_PIDS[@]}"; do
        pid="${BG_PIDS[$i]}"
        if wait "${pid}"; then
            SUCCEEDED=$((SUCCEEDED+1))
        else
            FAILED=$((FAILED+1))
        fi
        PROCESSED=$((PROCESSED+1))
    done
    BG_PIDS=()
    BG_ISSUES=()
}

while IFS= read -r ISSUE_JSON; do
    [[ $((PROCESSED + ${#BG_PIDS[@]})) -ge $((MAX_TASKS)) ]] && break

    ISSUE_ID="$(echo "${ISSUE_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")"

    if [[ $((MAX_PARALLEL)) -le 1 ]]; then
        # Sequential (default): run in foreground
        if _run_issue "${ISSUE_JSON}"; then
            SUCCEEDED=$((SUCCEEDED+1))
        else
            FAILED=$((FAILED+1))
        fi
        PROCESSED=$((PROCESSED+1))
    else
        # Parallel: launch in background, collect when pool is full
        _run_issue "${ISSUE_JSON}" &
        BG_PIDS+=($!)
        BG_ISSUES+=("${ISSUE_ID}")

        if [[ ${#BG_PIDS[@]} -ge $((MAX_PARALLEL)) ]]; then
            _wait_all_bg
        fi
    fi

done < <(echo "${ISSUES_JSON}" | python3 -c "
import json, sys
issues = json.load(sys.stdin)
for issue in issues:
    print(json.dumps(issue))
")

# Wait for any remaining background jobs
if [[ ${#BG_PIDS[@]} -gt 0 ]]; then
    _wait_all_bg
fi

log "SAIL complete: processed=${PROCESSED} succeeded=${SUCCEEDED} failed=${FAILED}"
[[ $((FAILED)) -eq 0 ]] || exit 1
