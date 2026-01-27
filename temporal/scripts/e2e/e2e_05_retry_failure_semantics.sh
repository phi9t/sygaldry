#!/usr/bin/env bash
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

main() {
  local run_dir
  local log_dir
  local worker_log
  local allow_json
  local allow_err
  local halt_out
  local halt_err
  local allow_workflow_id
  local halt_workflow_id
  local task_queue

  e2e::check_prereqs
  run_dir="$(e2e::new_tmp_dir)"
  log_dir="${run_dir}/logs"
  worker_log="${run_dir}/worker.log"
  allow_json="${run_dir}/allow.json"
  allow_err="${run_dir}/allow.err"
  halt_out="${run_dir}/halt.out"
  halt_err="${run_dir}/halt.err"
  task_queue="e2e05-queue-$(date +%s)-$$"

  cleanup() {
    e2e::stop_worker
    if [[ -n "${run_dir:-}" ]]; then
      rm -rf "${run_dir}"
    fi
  }
  trap cleanup EXIT

  mkdir -p "${log_dir}"
  e2e::ensure_temporal
  e2e::start_worker "${task_queue}" "${log_dir}" "${worker_log}"

  allow_workflow_id="e2e05-allow-$(date +%Y%m%d-%H%M%S)-$$"
  if ! e2e::retry_orchestrate "${allow_json}" "${allow_err}" run -workflow-id "${allow_workflow_id}" -task-queue "${task_queue}" -plan examples/e2e/retry_allow_failure.yaml -log-dir "${log_dir}" -output json; then
    cat "${allow_err}" >&2
    e2e::fail "allow-failure retry scenario failed"
  fi

  python3 - "${allow_json}" "${log_dir}/events.jsonl" "${allow_workflow_id}" <<'PY'
import json
import sys

result_path = sys.argv[1]
events_path = sys.argv[2]
workflow_id = sys.argv[3]

with open(result_path, 'r', encoding='utf-8') as f:
    raw = f.read()
start = raw.find('{')
if start < 0:
    raise SystemExit('missing JSON payload')
payload = json.loads(raw[start:])
steps = {step.get('id'): step for step in payload.get('result', {}).get('steps', [])}

flaky = steps.get('flaky')
failure_branch = steps.get('failure-branch')
success_branch = steps.get('success-branch')
if not flaky or not failure_branch or not success_branch:
    raise SystemExit('missing expected steps')
if flaky.get('state') != 'failed':
    raise SystemExit(f"flaky state expected failed, got {flaky.get('state')}")
if failure_branch.get('state') != 'success':
    raise SystemExit(f"failure-branch state expected success, got {failure_branch.get('state')}")
if success_branch.get('state') != 'skipped':
    raise SystemExit(f"success-branch state expected skipped, got {success_branch.get('state')}")

attempts = 0
with open(events_path, 'r', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        if event.get('workflowId') == workflow_id and event.get('stepId') == 'flaky' and event.get('status') == 'step_started':
            attempts += 1
if attempts < 3:
    raise SystemExit(f"expected at least 3 retry attempts for flaky, got {attempts}")
PY

  halt_workflow_id="e2e05-halt-$(date +%Y%m%d-%H%M%S)-$$"
  if e2e::retry_orchestrate "${halt_out}" "${halt_err}" run -workflow-id "${halt_workflow_id}" -task-queue "${task_queue}" -plan examples/e2e/halt_on_failure.yaml -log-dir "${log_dir}" -output json; then
    e2e::fail "halt-on-failure scenario should have failed"
  fi

  e2e::assert_contains "${halt_err}" "workflow failed"

  python3 - "${log_dir}/events.jsonl" "${halt_workflow_id}" <<'PY'
import json
import sys

path = sys.argv[1]
workflow_id = sys.argv[2]
ran_downstream = False

with open(path, 'r', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        if event.get('workflowId') != workflow_id:
            continue
        if event.get('stepId') == 'should-not-run' and event.get('status') == 'step_started':
            ran_downstream = True

if ran_downstream:
    raise SystemExit('downstream step unexpectedly started in halt-on-failure scenario')
PY

  e2e::log "E2E-05 passed"
}

main "$@"
