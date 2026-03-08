#!/usr/bin/env bash
# tools/agentic/run_improvement_loop.sh — Outer loop for SAIL.
#
# Discovers issues (or loads them from a file), then for each issue runs the
# improvement_loop.yaml Temporal pipeline. Retries on validation failure up to
# max_retries_per_task times using the retry prompt, and persists run artifacts
# so unattended wrappers can analyze the agent sessions afterward.
#
# Usage:
#   ./tools/agentic/run_improvement_loop.sh [--dry-run] [--repo-dir <path>] \
#       [--run-id <id>] [--artifacts-dir <path>] [--issues-file <path>]
#
# Environment overrides (also readable from config.yaml):
#   SAIL_PLANNER_ENGINE     SAIL_PLANNER_MODEL
#   SAIL_IMPLEMENTER_ENGINE SAIL_IMPLEMENTER_MODEL
#   SAIL_MAX_TASKS          SAIL_MAX_RETRIES    SAIL_MIN_PRIORITY
#   SAIL_MAX_PARALLEL       (only 1 is supported on a single checkout)
#   SAIL_RUN_ID             SAIL_ARTIFACTS_DIR  SAIL_ISSUES_FILE
#   SAIL_RUN_KIND           TEMPORAL_ADDRESS    TEMPORAL_NAMESPACE
#   TEMPORAL_TASK_QUEUE

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
DEFAULT_REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly DEFAULT_REPO_DIR
CONFIG="${SCRIPT_DIR}/config.yaml"
readonly CONFIG
PLAN_FILE="${SCRIPT_DIR}/improvement_loop.yaml"
readonly PLAN_FILE
MAJOR_PLAN_FILE="${SCRIPT_DIR}/major_improvement_loop.yaml"
readonly MAJOR_PLAN_FILE
DISCOVER="${SCRIPT_DIR}/discover_issues.py"
readonly DISCOVER

REPO_DIR="${DEFAULT_REPO_DIR}"
TEMPORAL_DIR=""
ATTEMPTED_FILE=""
BASE_BRANCH="main"
DRY_RUN=false
RUN_ID="${SAIL_RUN_ID:-}"
ARTIFACTS_DIR="${SAIL_ARTIFACTS_DIR:-}"
ISSUES_FILE="${SAIL_ISSUES_FILE:-}"
RUN_KIND="${SAIL_RUN_KIND:-primary}"
LANDING_MODE=""
RUNTIME_ROOT="${SAIL_RUNTIME_ROOT:-/mnt/data_infra/zephyr_container_infra/sygaldry/logs/sail}"

RUN_FILE=""
DISCOVERED_ISSUES_FILE=""
DISCOVERY_STATS_FILE=""
ISSUE_ATTEMPTS_FILE=""

RUN_STARTED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
FINAL_STATUS="failed"
PROCESSED=0
SUCCEEDED=0
FAILED=0
TOTAL=0

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] [SAIL:${BASH_LINENO[0]}] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

_touch_heartbeat() {
    if [[ -n "${SAIL_HEARTBEAT_FILE:-}" ]]; then
        mkdir -p "$(dirname "${SAIL_HEARTBEAT_FILE}")"
        touch "${SAIL_HEARTBEAT_FILE}"
    fi
}

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
        ' "${CONFIG}" 2>/dev/null || true
    )"
    echo "${value:-${default}}"
}

_json_len() {
    python3 -c "import json,sys; print(len(json.load(sys.stdin)))"
}

_json_get_issue_field() {
    local issue_json="$1" field="$2"
    python3 - "$issue_json" "$field" <<'PY'
import json
import sys

issue = json.loads(sys.argv[1])
field = sys.argv[2]
value = issue.get(field, "")
if isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
else:
    print(value)
PY
}

_record_attempt_registry() {
    local issue_id="$1" status="$2" branch="$3" pr_url="$4" workflow_id="$5" temporal_run_id="$6"
    python3 - "$ATTEMPTED_FILE" "$issue_id" "$status" "$branch" "$pr_url" "$workflow_id" "$temporal_run_id" <<'PY'
import datetime as dt
import json
import sys

path, issue_id, status, branch, pr_url, workflow_id, temporal_run_id = sys.argv[1:8]
record = {
    "issue_id": issue_id,
    "status": status,
    "branch": branch,
    "pr_url": pr_url,
    "workflow_id": workflow_id,
    "temporal_run_id": temporal_run_id,
    "timestamp": dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z"),
}
with open(path, "a", encoding="utf-8") as file:
    file.write(json.dumps(record, sort_keys=True) + "\n")
PY
}

_record_issue_attempt() {
    local issue_json="$1" status="$2" branch="$3" attempt="$4" workflow_id="$5" temporal_run_id="$6"
    local log_dir="$7" prompt_file="$8" exit_code="$9" pr_url="${10}" patch_file="${11}"
    local failure_context_file="${12}" note="${13}" started_at="${14}"
    python3 - "$ISSUE_ATTEMPTS_FILE" "$issue_json" "$status" "$branch" "$attempt" \
        "$workflow_id" "$temporal_run_id" "$log_dir" "$prompt_file" "$exit_code" \
        "$pr_url" "$patch_file" "$failure_context_file" "$note" "$started_at" "$RUN_ID" "$RUN_KIND" <<'PY'
import datetime as dt
import json
import sys

(
    path,
    issue_raw,
    status,
    branch,
    attempt,
    workflow_id,
    temporal_run_id,
    log_dir,
    prompt_file,
    exit_code,
    pr_url,
    patch_file,
    failure_context_file,
    note,
    started_at,
    sail_run_id,
    run_kind,
) = sys.argv[1:18]
issue = json.loads(issue_raw)
record = {
    "sailRunId": sail_run_id,
    "runKind": run_kind,
    "issueId": issue.get("id", ""),
    "issueTitle": issue.get("title", ""),
    "issueType": issue.get("type", ""),
    "issuePriority": issue.get("priority"),
    "status": status,
    "branch": branch,
    "attempt": int(attempt),
    "workflowId": workflow_id,
    "temporalRunId": temporal_run_id,
    "logDir": log_dir,
    "promptFile": prompt_file,
    "exitCode": int(exit_code),
    "prUrl": pr_url,
    "patchFile": patch_file,
    "failureContextFile": failure_context_file,
    "note": note,
    "startedAt": started_at,
    "finishedAt": dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z"),
}
with open(path, "a", encoding="utf-8") as file:
    file.write(json.dumps(record, sort_keys=True) + "\n")
PY
}

_write_run_metadata() {
    local status="$1"
    python3 - "$RUN_FILE" "$status" "$RUN_ID" "$RUN_KIND" "$RUN_STARTED_AT" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        "$REPO_DIR" "$BASE_BRANCH" "$DRY_RUN" "$ARTIFACTS_DIR" "$ISSUES_FILE" "$PROCESSED" \
        "$SUCCEEDED" "$FAILED" "$TOTAL" "$PLANNER_ENGINE" "$PLANNER_MODEL" \
        "$IMPLEMENTER_ENGINE" "$IMPLEMENTER_MODEL" "$MAX_TASKS" "$MAX_RETRIES" \
        "$MIN_PRIORITY" "$MAX_PARALLEL" "$TEMPORAL_ADDRESS" "$TEMPORAL_NAMESPACE" \
        "$TEMPORAL_TASK_QUEUE" "$LANDING_MODE" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

(
    path,
    status,
    run_id,
    run_kind,
    started_at,
    finished_at,
    repo_dir,
    base_branch,
    dry_run,
    artifacts_dir,
    issues_file,
    processed,
    succeeded,
    failed,
    total,
    planner_engine,
    planner_model,
    implementer_engine,
    implementer_model,
    max_tasks,
    max_retries,
    min_priority,
    max_parallel,
    temporal_address,
    temporal_namespace,
    temporal_task_queue,
    landing_mode,
) = sys.argv[1:28]

repo = Path(repo_dir)

def git_value(*args: str) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(repo), *args],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        return ""

payload = {
    "runId": run_id,
    "runKind": run_kind,
    "status": status,
    "startedAt": started_at,
    "finishedAt": finished_at,
    "repoDir": repo_dir,
    "baseBranch": base_branch,
    "currentBranch": git_value("branch", "--show-current"),
    "gitHead": git_value("rev-parse", "HEAD"),
    "gitHeadShort": git_value("rev-parse", "--short", "HEAD"),
    "dryRun": dry_run == "true",
    "artifactsDir": artifacts_dir,
    "issuesFile": issues_file,
    "counts": {
        "discovered": int(total),
        "processed": int(processed),
        "succeeded": int(succeeded),
        "failed": int(failed),
    },
    "config": {
        "planner": {"engine": planner_engine, "model": planner_model},
        "implementer": {"engine": implementer_engine, "model": implementer_model},
        "loop": {
            "maxTasks": int(max_tasks),
            "maxRetries": int(max_retries),
            "minPriority": int(min_priority),
            "maxParallel": int(max_parallel),
        },
        "temporal": {
            "address": temporal_address,
            "namespace": temporal_namespace,
            "taskQueue": temporal_task_queue,
        },
        "repo": {
            "baseBranch": base_branch,
            "landingMode": landing_mode,
        },
    },
}
Path(path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

_load_run_result() {
    local stdout_file="$1" fallback_workflow_id="$2" fallback_run_id="$3" normalized_file="$4"
    python3 - "$stdout_file" "$fallback_workflow_id" "$fallback_run_id" "$normalized_file" <<'PY'
import json
import sys
from pathlib import Path

stdout_file, fallback_workflow_id, fallback_run_id, normalized_file = sys.argv[1:5]
path = Path(stdout_file)
payload = {}
if path.exists():
    raw = path.read_text(encoding="utf-8", errors="replace")
    start = raw.find("{")
    if start >= 0:
        try:
            payload = json.loads(raw[start:])
        except json.JSONDecodeError:
            payload = {}
if not payload:
    payload = {
        "workflowId": fallback_workflow_id,
        "runId": fallback_run_id,
        "async": False,
        "result": None,
    }
Path(normalized_file).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
print(payload.get("workflowId", ""))
print(payload.get("runId", ""))
steps = payload.get("result", {}).get("steps", []) if isinstance(payload.get("result"), dict) else []
pr_url = ""
landed_branch = ""
patch_file = ""
validate_failed = False
for step in steps:
    if step.get("id") == "create_pr":
        pr_url = step.get("result", {}).get("outputs", {}).get("pr_url", "")
        landed_branch = step.get("result", {}).get("outputs", {}).get("landed_branch", "")
    if step.get("id") == "validate" and step.get("state") == "failed":
        validate_failed = True
    if step.get("id") == "rollback":
        patch_file = step.get("result", {}).get("outputs", {}).get("patch_file", "")
disposition = "workflow_failed"
if pr_url:
    disposition = "pr_created"
elif landed_branch:
    disposition = "landed"
elif validate_failed or patch_file:
    disposition = "rolled_back"
elif payload.get("result") is None:
    disposition = "workflow_failed"
else:
    disposition = "completed_without_pr"
print(pr_url)
print(landed_branch)
print(patch_file)
print(disposition)
PY
}

_manifest_ids_from_log_dir() {
    local log_dir="$1"
    python3 - "$log_dir" <<'PY'
import json
import sys
from pathlib import Path

for manifest in sorted(Path(sys.argv[1]).glob("*_plan.json")):
    try:
        payload = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        continue
    workflow_id = payload.get("workflowId", "")
    run_id = payload.get("runId", "")
    if workflow_id and run_id:
        print(workflow_id)
        print(run_id)
        break
PY
}

_summarize_validate_failure() {
    local validate_stdout="$1" validate_stderr="$2"
    python3 - "$validate_stdout" "$validate_stderr" <<'PY'
import hashlib
import sys
from pathlib import Path


def read_lines(path_value: str) -> list[str]:
    if not path_value:
        return []
    path = Path(path_value)
    if not path.exists():
        return []
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []


paths = sys.argv[1:3]
candidates: list[str] = []
for raw_path in paths:
    for line in read_lines(raw_path):
        text = line.strip()
        if text.startswith("[validate] FAIL:"):
            candidates.append(text)

if not candidates:
    for raw_path in paths:
        for line in read_lines(raw_path):
            text = line.strip()
            if text.startswith("[validate]") and (
                "failed" in text.lower() or "error" in text.lower()
            ):
                candidates.append(text)

if not candidates:
    for raw_path in paths:
        tail = [line.strip() for line in read_lines(raw_path) if line.strip()]
        candidates.extend(tail[-4:])

summary: list[str] = []
seen: set[str] = set()
for line in candidates:
    if line in seen:
        continue
    seen.add(line)
    summary.append(line)
summary = summary[-6:]

for line in summary:
    print(line)

text = "\n".join(summary).strip()
if text:
    print(f"__SIGNATURE__ {hashlib.sha1(text.encode()).hexdigest()[:12]}")
PY
}

_capture_validate_failure() {
    local log_dir="$1" failure_context_file="$2" workflow_id="$3"
    local validate_stderr validate_stdout previous_signature summary_output failure_signature failure_summary
    validate_stderr="$(find "${log_dir}" -name "*validate*stderr*" -type f 2>/dev/null | head -1)"
    validate_stdout="$(find "${log_dir}" -name "*validate*stdout*" -type f 2>/dev/null | head -1)"
    previous_signature=""
    if [[ -f "${failure_context_file}" ]]; then
        previous_signature="$(
            grep '^Failure summary signature:' "${failure_context_file}" 2>/dev/null \
                | tail -1 \
                | sed 's/^Failure summary signature:[[:space:]]*//'
        )"
    fi
    summary_output="$(_summarize_validate_failure "${validate_stdout}" "${validate_stderr}")"
    failure_signature="$(echo "${summary_output}" | awk '/^__SIGNATURE__ /{print $2}')"
    failure_summary="$(echo "${summary_output}" | sed '/^__SIGNATURE__ /d')"
    if [[ (-n "${validate_stderr}" && -f "${validate_stderr}") || (-n "${validate_stdout}" && -f "${validate_stdout}") ]]; then
        {
            echo "Workflow: ${workflow_id}"
            if [[ -n "${validate_stdout}" && -f "${validate_stdout}" ]]; then
                echo "=== validate stdout ==="
                tail -120 "${validate_stdout}"
            fi
            if [[ -n "${validate_stderr}" && -f "${validate_stderr}" ]]; then
                echo "=== validate stderr ==="
                tail -120 "${validate_stderr}"
            fi
            if [[ -n "${failure_summary}" ]]; then
                echo "=== validate failure summary ==="
                printf '%s\n' "${failure_summary}"
            fi
            if [[ -n "${failure_signature}" ]]; then
                echo "Failure summary signature: ${failure_signature}"
                if [[ -n "${previous_signature}" && "${previous_signature}" == "${failure_signature}" ]]; then
                    echo "Repeated validate failure signature detected from the prior retry."
                    echo "Retry guidance: do not repeat the previous fix; target the failing check(s) above or inspect the rollback patch."
                fi
            fi
        } > "${failure_context_file}"
        log "   validation failure captured to ${failure_context_file}"
    else
        echo "No validation stderr captured for ${workflow_id}." > "${failure_context_file}"
    fi
}

_attempt_plan_file() {
    local attempt="$1" attempt_dir="$2" issue_type="$3"
    local source_plan implementer_prompt retry_prompt
    if [[ "${issue_type}" == "major_challenge" ]]; then
        source_plan="${MAJOR_PLAN_FILE}"
        implementer_prompt="tools/agentic/prompts/major_implementer.md"
        retry_prompt="tools/agentic/prompts/major_retry.md"
    else
        source_plan="${PLAN_FILE}"
        implementer_prompt="tools/agentic/prompts/implementer.md"
        retry_prompt="tools/agentic/prompts/retry.md"
    fi
    if [[ "${attempt}" -eq 0 ]]; then
        echo "${source_plan}"
        return 0
    fi

    local retry_plan="${attempt_dir}/improvement_loop.retry.yaml"
    sed "s|prompt_file: ${implementer_prompt}|prompt_file: ${retry_prompt}|" \
        "${source_plan}" > "${retry_plan}"
    grep -q "prompt_file: ${retry_prompt}" "${retry_plan}" \
        || die "retry plan generation failed for ${retry_plan}"
    echo "${retry_plan}"
}

_append_retry_patch_context() {
    local failure_context_file="$1" patch_file="$2"
    if [[ -z "${patch_file}" ]]; then
        return 0
    fi
    {
        echo
        echo "Review rollback patch from the previous attempt: ${patch_file}"
    } >> "${failure_context_file}"
}

_restore_repo_state() {
    local branch="$1"
    if [[ ! -d "${REPO_DIR}/.git" ]]; then
        return 0
    fi
    git -C "${REPO_DIR}" checkout "${BASE_BRANCH}" >/dev/null 2>&1 || true
    if [[ -n "${branch}" ]] && git -C "${REPO_DIR}" show-ref --verify --quiet "refs/heads/${branch}"; then
        git -C "${REPO_DIR}" branch -D "${branch}" >/dev/null 2>&1 || true
    fi
}

_update_major_challenge_state() {
    local issue_json="$1" attempt_status="$2" workflow_id="$3" temporal_run_id="$4" note="$5"
    local issue_type
    issue_type="$(_json_get_issue_field "${issue_json}" type)"
    if [[ "${issue_type}" != "major_challenge" ]]; then
        return 0
    fi
    python3 "${SCRIPT_DIR}/update_major_challenge_state.py" \
        --runtime-root "${RUNTIME_ROOT}" \
        --repo-dir "${REPO_DIR}" \
        --issue-json "${issue_json}" \
        --attempt-status "${attempt_status}" \
        --run-id "${RUN_ID}" \
        --workflow-id "${workflow_id}" \
        --temporal-run-id "${temporal_run_id}" \
        --max-failed-runs "${MAJOR_MAX_FAILED_RUNS}" \
        --note "${note}"
}

_is_already_handled() {
    local issue_id="$1"
    if grep -q "\"${issue_id}\"" "${ATTEMPTED_FILE}" 2>/dev/null; then
        local last_status
        last_status="$(
            grep "\"${issue_id}\"" "${ATTEMPTED_FILE}" \
                | python3 -c "import json,sys; entries=list(map(json.loads,sys.stdin)); print(entries[-1].get('status',''))" 2>/dev/null || true
        )"
        if [[ "${last_status}" == "pr_created" || "${last_status}" == "landed" || "${last_status}" == "skipped" ]]; then
            return 0
        fi
    fi
    return 1
}

_load_issues() {
    if [[ -n "${ISSUES_FILE}" ]]; then
        [[ -f "${ISSUES_FILE}" ]] || die "issues file not found: ${ISSUES_FILE}"
        cp "${ISSUES_FILE}" "${DISCOVERED_ISSUES_FILE}"
        TOTAL="$(_json_len <"${DISCOVERED_ISSUES_FILE}")"
        python3 - "$DISCOVERY_STATS_FILE" "$REPO_DIR" "$ISSUES_FILE" "$TOTAL" <<'PY'
import datetime as dt
import json
import sys

path, repo_dir, issues_file, total = sys.argv[1:5]
payload = {
    "repoDir": repo_dir,
    "mode": "issues_file",
    "issuesFile": issues_file,
    "startedAt": dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z"),
    "finishedAt": dt.datetime.now(dt.UTC).isoformat().replace("+00:00", "Z"),
    "durationSec": 0.0,
    "sources": [
        {
            "name": "issues_file",
            "durationSec": 0.0,
            "count": int(total),
            "error": "",
        }
    ],
}
with open(path, "w", encoding="utf-8") as file:
    json.dump(payload, file, indent=2, sort_keys=True)
    file.write("\n")
PY
        ISSUES_JSON="$(cat "${DISCOVERED_ISSUES_FILE}")"
        return
    fi

    python3 "${DISCOVER}" \
        --repo-dir "${REPO_DIR}" \
        --min-priority "${MIN_PRIORITY}" \
        --max-per-type 20 \
        --stats-file "${DISCOVERY_STATS_FILE}" > "${DISCOVERED_ISSUES_FILE}"
    TOTAL="$(_json_len <"${DISCOVERED_ISSUES_FILE}")"
    ISSUES_JSON="$(cat "${DISCOVERED_ISSUES_FILE}")"
}

_run_issue() {
    local issue_json="$1"
    local issue_id issue_title issue_type issue_priority timestamp slug branch_name workflow_id
    issue_id="$(_json_get_issue_field "${issue_json}" id)"
    issue_title="$(_json_get_issue_field "${issue_json}" title)"
    issue_type="$(_json_get_issue_field "${issue_json}" type)"
    issue_priority="$(_json_get_issue_field "${issue_json}" priority)"
    timestamp="$(date +'%Y%m%d-%H%M%S')"
    slug="$(echo "${issue_id}" | tr '/' '-' | tr '[:upper:]' '[:lower:]')"
    if [[ "${LANDING_MODE}" == "direct" ]]; then
        branch_name="${BASE_BRANCH}"
    else
        branch_name="agentic/${timestamp}-${slug}"
    fi
    workflow_id="sail-${timestamp}-${slug}"

    local issue_dir="${ARTIFACTS_DIR}/issues/${slug}"
    local failure_context_file="${issue_dir}/last_failure.txt"
    mkdir -p "${issue_dir}"

    log "── issue ${issue_id}: ${issue_title}"
    log "   branch: ${branch_name}"

    if _is_already_handled "${issue_id}"; then
        log "   skipping ${issue_id}: already handled in a previous run"
        _record_issue_attempt "${issue_json}" "skipped_registry" "${branch_name}" 0 "" "" "" "" 0 "" "" "" \
            "already handled in attempted registry" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        return 0
    fi

    if [[ "${LANDING_MODE}" != "direct" ]] && \
        git -C "${REPO_DIR}" ls-remote --heads origin "agentic/*-${slug}" 2>/dev/null | grep -q .; then
        log "   skipping ${issue_id}: branch agentic/*-${slug} already exists on origin"
        _record_attempt_registry "${issue_id}" "skipped" "${branch_name}" "" "" ""
        _record_issue_attempt "${issue_json}" "skipped_remote_branch" "${branch_name}" 0 "" "" "" "" 0 "" "" "" \
            "remote branch already exists" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        return 0
    fi

    local attempt=0 success=false pr_url="" landed_branch="" patch_file="" temporal_run_id="" final_workflow_id=""
    while [[ ${attempt} -le ${MAX_RETRIES} ]]; do
        local attempt_number=$((attempt + 1))
        local attempt_started_at
        attempt_started_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        local attempt_dir="${issue_dir}/attempt-${attempt_number}"
        local log_dir="${attempt_dir}/logs"
        local stdout_file="${attempt_dir}/orchestrate.stdout"
        local stderr_file="${attempt_dir}/orchestrate.stderr"
        local result_file="${attempt_dir}/orchestrate_result.json"
        mkdir -p "${log_dir}"
        _touch_heartbeat

        if [[ "${DRY_RUN}" == "true" ]]; then
            log "   [dry-run] would run orchestrate for issue ${issue_id} (attempt ${attempt_number})"
            printf '{\n  "workflowId": "%s",\n  "runId": "",\n  "async": false,\n  "result": null\n}\n' \
                "${workflow_id}-a${attempt}" > "${result_file}"
            _record_issue_attempt "${issue_json}" "dry_run" "${branch_name}" "${attempt_number}" \
                "${workflow_id}-a${attempt}" "" "${log_dir}" "" 0 "" "" "" \
                "dry-run invocation" "${attempt_started_at}"
            success=true
            break
        fi

        log "   attempt ${attempt_number}/$((MAX_RETRIES + 1))"

        local prompt_file="${SCRIPT_DIR}/generate_plan.py"
        if [[ "${issue_type}" == "major_challenge" ]]; then
            prompt_file="${SCRIPT_DIR}/prompts/major_planner.md"
        fi
        local plan_to_run
        plan_to_run="$(_attempt_plan_file "${attempt}" "${attempt_dir}" "${issue_type}")"

        local failure_ctx_flag=""
        if [[ ${attempt} -gt 0 && -f "${failure_context_file}" ]]; then
            failure_ctx_flag="${failure_context_file}"
        fi

        local exit_code=0
        _touch_heartbeat
        (
            cd "${TEMPORAL_DIR}"
            go run ./cmd/orchestrate run \
                -plan "${plan_to_run}" \
                -log-dir "${log_dir}" \
                -address "${TEMPORAL_ADDRESS}" \
                -namespace "${TEMPORAL_NAMESPACE}" \
                -task-queue "${TEMPORAL_TASK_QUEUE}" \
                -workflow-id "${workflow_id}-a${attempt}" \
                -output json \
                -set "issue_json=${issue_json}" \
                -set "issue_title=${issue_title}" \
                -set "issue_type=${issue_type}" \
                -set "branch_name=${branch_name}" \
                -set "repo_dir=${REPO_DIR}" \
                -set "workflow_id=${workflow_id}-a${attempt}" \
                -set "implementer_engine=${IMPLEMENTER_ENGINE}" \
                -set "implementer_model=${IMPLEMENTER_MODEL}" \
                -set "major_planner_engine=${MAJOR_PLANNER_ENGINE}" \
                -set "major_planner_model=${MAJOR_PLANNER_MODEL}" \
                -set "major_max_changed_files=${MAJOR_MAX_CHANGED_FILES}" \
                -set "major_max_changed_lines=${MAJOR_MAX_CHANGED_LINES}" \
                -set "failure_context_file=${failure_ctx_flag}" \
                >"${stdout_file}" 2>"${stderr_file}"
        ) || exit_code=$?
        _touch_heartbeat

        local workflow_manifest_ids
        workflow_manifest_ids="$(_manifest_ids_from_log_dir "${log_dir}")"
        local manifest_workflow_id="" manifest_run_id=""
        if [[ -n "${workflow_manifest_ids}" ]]; then
            manifest_workflow_id="$(echo "${workflow_manifest_ids}" | sed -n '1p')"
            manifest_run_id="$(echo "${workflow_manifest_ids}" | sed -n '2p')"
        fi

        local run_result
        run_result="$(_load_run_result "${stdout_file}" "${manifest_workflow_id:-${workflow_id}-a${attempt}}" "${manifest_run_id}" "${result_file}")"
        local parsed_workflow_id parsed_run_id workflow_disposition
        parsed_workflow_id="$(echo "${run_result}" | sed -n '1p')"
        parsed_run_id="$(echo "${run_result}" | sed -n '2p')"
        pr_url="$(echo "${run_result}" | sed -n '3p')"
        landed_branch="$(echo "${run_result}" | sed -n '4p')"
        patch_file="$(echo "${run_result}" | sed -n '5p')"
        workflow_disposition="$(echo "${run_result}" | sed -n '6p')"
        final_workflow_id="${parsed_workflow_id}"
        temporal_run_id="${parsed_run_id}"

        if [[ ${exit_code} -eq 0 && ("${workflow_disposition}" == "pr_created" || "${workflow_disposition}" == "landed") ]]; then
            _record_issue_attempt "${issue_json}" "success" "${branch_name}" "${attempt_number}" \
                "${parsed_workflow_id}" "${parsed_run_id}" "${log_dir}" "${prompt_file}" "${exit_code}" \
                "${pr_url}" "${patch_file}" "${failure_ctx_flag}" \
                "issue_type=${issue_type} priority=${issue_priority}" "${attempt_started_at}"
            success=true
            break
        fi

        log "   attempt ${attempt_number} failed (exit=${exit_code}, disposition=${workflow_disposition})"
        _capture_validate_failure "${log_dir}" "${failure_context_file}" "${parsed_workflow_id:-${workflow_id}-a${attempt}}"
        _append_retry_patch_context "${failure_context_file}" "${patch_file}"
        _record_issue_attempt "${issue_json}" "failed_attempt" "${branch_name}" "${attempt_number}" \
            "${parsed_workflow_id}" "${parsed_run_id}" "${log_dir}" "${prompt_file}" "${exit_code}" \
            "${pr_url}" "${patch_file}" "${failure_context_file}" \
            "orchestrate failed disposition=${workflow_disposition}" "${attempt_started_at}"
        attempt=$((attempt + 1))
    done

    _restore_repo_state "${branch_name}"

    if [[ "${success}" == "true" ]]; then
        log "   ✓ issue ${issue_id} handled"
        _update_major_challenge_state "${issue_json}" "success" "${final_workflow_id}" "${temporal_run_id}" \
            "workflow_disposition=${workflow_disposition}"
        _record_attempt_registry "${issue_id}" "${workflow_disposition}" "${branch_name}" "${pr_url}" "${final_workflow_id}" "${temporal_run_id}"
        return 0
    fi

    log "   ✗ issue ${issue_id} exhausted retries"
    _update_major_challenge_state "${issue_json}" "failed" "${final_workflow_id}" "${temporal_run_id}" \
        "workflow_disposition=${workflow_disposition}"
    _record_attempt_registry "${issue_id}" "failed" "${branch_name}" "${pr_url}" "${final_workflow_id}" "${temporal_run_id}"
    return 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --repo-dir) REPO_DIR="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --artifacts-dir) ARTIFACTS_DIR="$2"; shift 2 ;;
        --issues-file) ISSUES_FILE="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

REPO_DIR="$(cd "${REPO_DIR}" && pwd)"
TEMPORAL_DIR="${REPO_DIR}/temporal"
ATTEMPTED_FILE="${REPO_DIR}/.agentic/attempted.jsonl"

PLANNER_ENGINE="${SAIL_PLANNER_ENGINE:-$(_cfg_section planner engine local)}"
PLANNER_MODEL="${SAIL_PLANNER_MODEL-$(_cfg_section planner model '')}"
IMPLEMENTER_ENGINE="${SAIL_IMPLEMENTER_ENGINE:-$(_cfg_section implementer engine claude)}"
IMPLEMENTER_MODEL="${SAIL_IMPLEMENTER_MODEL-$(_cfg_section implementer model claude-sonnet-4-6)}"
MAJOR_PLANNER_ENGINE="${SAIL_MAJOR_PLANNER_ENGINE:-${IMPLEMENTER_ENGINE}}"
MAJOR_PLANNER_MODEL="${SAIL_MAJOR_PLANNER_MODEL:-${IMPLEMENTER_MODEL}}"
MAJOR_MAX_CHANGED_FILES="${SAIL_MAJOR_MAX_CHANGED_FILES:-8}"
MAJOR_MAX_CHANGED_LINES="${SAIL_MAJOR_MAX_CHANGED_LINES:-600}"
MAJOR_MAX_FAILED_RUNS="${SAIL_MAJOR_MAX_FAILED_RUNS:-3}"
MAX_TASKS="${SAIL_MAX_TASKS:-$(_cfg_section loop max_tasks_per_run 3)}"
MAX_RETRIES="${SAIL_MAX_RETRIES:-$(_cfg_section loop max_retries_per_task 2)}"
MIN_PRIORITY="${SAIL_MIN_PRIORITY:-$(_cfg_section loop min_priority 2)}"
MAX_PARALLEL="${SAIL_MAX_PARALLEL:-$(_cfg_section loop max_parallel 1)}"
BASE_BRANCH="${SAIL_BASE_BRANCH:-$(_cfg_section repo base_branch main)}"
LANDING_MODE="${SAIL_LANDING_MODE:-$(_cfg_section repo landing_mode direct)}"

TEMPORAL_ADDRESS="${TEMPORAL_ADDRESS:-localhost:7233}"
TEMPORAL_NAMESPACE="${TEMPORAL_NAMESPACE:-default}"
TEMPORAL_TASK_QUEUE="${TEMPORAL_TASK_QUEUE:-orchestration}"

if [[ "${MAX_PARALLEL}" -gt 1 ]]; then
    die "SAIL_MAX_PARALLEL > 1 is not supported on a single checkout"
fi
if [[ "${LANDING_MODE}" != "direct" && "${LANDING_MODE}" != "pull_request" ]]; then
    die "SAIL landing mode must be 'direct' or 'pull_request' (got: ${LANDING_MODE})"
fi

if [[ -z "${RUN_ID}" ]]; then
    RUN_ID="sailrun-$(date +'%Y%m%d-%H%M%S')"
fi
if [[ -z "${ARTIFACTS_DIR}" ]]; then
    ARTIFACTS_DIR="/tmp/sail-runs/${RUN_ID}"
fi
if [[ "${ARTIFACTS_DIR}" != /* ]]; then
    ARTIFACTS_DIR="${REPO_DIR}/${ARTIFACTS_DIR}"
fi

RUN_FILE="${ARTIFACTS_DIR}/run.json"
DISCOVERED_ISSUES_FILE="${ARTIFACTS_DIR}/discovered_issues.json"
DISCOVERY_STATS_FILE="${ARTIFACTS_DIR}/discovery_stats.json"
ISSUE_ATTEMPTS_FILE="${ARTIFACTS_DIR}/issue_attempts.jsonl"

mkdir -p "${ARTIFACTS_DIR}" "$(dirname "${ATTEMPTED_FILE}")"
touch "${ATTEMPTED_FILE}" "${ISSUE_ATTEMPTS_FILE}"
_touch_heartbeat

_write_run_metadata "running"
trap '_write_run_metadata "${FINAL_STATUS}"' EXIT

log "SAIL starting (run_id=${RUN_ID}, run_kind=${RUN_KIND}, dry_run=${DRY_RUN}, max_tasks=${MAX_TASKS}, max_retries=${MAX_RETRIES})"
log "planner: engine=${PLANNER_ENGINE} model=${PLANNER_MODEL}"
log "implementer: engine=${IMPLEMENTER_ENGINE} model=${IMPLEMENTER_MODEL}"
log "major planner: engine=${MAJOR_PLANNER_ENGINE} model=${MAJOR_PLANNER_MODEL}"
log "landing: mode=${LANDING_MODE} base_branch=${BASE_BRANCH}"
log "artifacts: ${ARTIFACTS_DIR}"

if [[ "${DRY_RUN}" != "true" ]]; then
    TEMPORAL_HOST="${TEMPORAL_ADDRESS%%:*}"
    TEMPORAL_PORT="${TEMPORAL_ADDRESS##*:}"
    if ! nc -z "${TEMPORAL_HOST}" "${TEMPORAL_PORT}" 2>/dev/null; then
        die "Temporal server not reachable at ${TEMPORAL_ADDRESS}; start the worker first"
    fi
    log "Temporal server reachable at ${TEMPORAL_ADDRESS}"
fi

_load_issues
_touch_heartbeat
log "discovered ${TOTAL} issues (min_priority<=${MIN_PRIORITY})"

if [[ "${TOTAL}" -eq 0 ]]; then
    FINAL_STATUS="success"
    _touch_heartbeat
    log "no issues to fix; exiting"
    exit 0
fi

while IFS= read -r issue_json; do
    [[ ${PROCESSED} -ge ${MAX_TASKS} ]] && break
    if _run_issue "${issue_json}"; then
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
    PROCESSED=$((PROCESSED + 1))
    _touch_heartbeat
done < <(echo "${ISSUES_JSON}" | python3 -c '
import json
import sys
for issue in json.load(sys.stdin):
    print(json.dumps(issue, separators=(",", ":")))
')

_touch_heartbeat
log "SAIL complete: processed=${PROCESSED} succeeded=${SUCCEEDED} failed=${FAILED}"
if [[ ${FAILED} -eq 0 ]]; then
    FINAL_STATUS="success"
    _touch_heartbeat
    exit 0
fi
FINAL_STATUS="failed"
_touch_heartbeat
exit 1
