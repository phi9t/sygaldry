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
  local out_json
  local err_log
  local status_json
  local summary_out
  local workflow_id
  local run_id
  local task_queue

  e2e::check_prereqs
  run_dir="$(e2e::new_tmp_dir)"
  log_dir="${run_dir}/logs"
  worker_log="${run_dir}/worker.log"
  out_json="${run_dir}/run_async.json"
  err_log="${run_dir}/orchestrate.err"
  status_json="${run_dir}/status.json"
  summary_out="${run_dir}/summary.txt"
  task_queue="e2e01-queue-$(date +%s)-$$"

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

  workflow_id="e2e01-$(date +%Y%m%d-%H%M%S)-$$"
  if ! e2e::retry_orchestrate "${out_json}" "${err_log}" run -workflow-id "${workflow_id}" -task-queue "${task_queue}" -plan examples/e2e_test.yaml -log-dir "${log_dir}" -output json -async; then
    cat "${err_log}" >&2
    e2e::fail "async run failed"
  fi

  run_id="$(python3 - "${out_json}" <<'PY'
import json
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    raw = f.read()
start = raw.find('{')
if start < 0:
    raise SystemExit('missing JSON payload')
payload = json.loads(raw[start:])
if not payload.get('workflowId') or not payload.get('runId'):
    raise SystemExit('missing workflowId/runId')
if payload.get('async') is not True:
    raise SystemExit('async flag not true')
print(payload['runId'])
PY
)"

  if ! e2e::wait_for_terminal_status "${workflow_id}" 180 "${status_json}"; then
    e2e::fail "workflow ${workflow_id} did not reach terminal status"
  fi

  e2e::assert_contains "${status_json}" "\"workflowId\": \"${workflow_id}\""
  e2e::assert_contains "${status_json}" "Completed"

  (
    cd "${E2E_ROOT_DIR}"
    ./scripts/logs_cli.py --log-dir "${log_dir}" summary --latest >"${summary_out}"
  )
  e2e::assert_contains "${summary_out}" "Pipeline: ${workflow_id}"
  e2e::assert_contains "${summary_out}" "Run: ${run_id}"

  e2e::log "E2E-01 passed"
}

main "$@"
