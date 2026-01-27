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
  local run_json
  local run_err
  local workflow_id
  local task_queue

  e2e::check_prereqs
  run_dir="$(e2e::new_tmp_dir)"
  log_dir="${run_dir}/logs"
  worker_log="${run_dir}/worker.log"
  run_json="${run_dir}/run.json"
  run_err="${run_dir}/run.err"
  task_queue="e2e06-queue-$(date +%s)-$$"

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

  workflow_id="e2e06-$(date +%Y%m%d-%H%M%S)-$$"
  if ! e2e::retry_orchestrate "${run_json}" "${run_err}" run -workflow-id "${workflow_id}" -task-queue "${task_queue}" -plan examples/e2e/streaming_dag.yaml -log-dir "${log_dir}" -output json; then
    cat "${run_err}" >&2
    e2e::fail "streaming DAG scenario failed"
  fi

  python3 - "${log_dir}/events.jsonl" "${workflow_id}" <<'PY'
import json
import sys
from datetime import datetime

path = sys.argv[1]
workflow_id = sys.argv[2]

fast_downstream_started = None
slow_branch_finished = None

def parse_ts(value):
    if value.endswith('Z'):
        value = value[:-1] + '+00:00'
    return datetime.fromisoformat(value)

with open(path, 'r', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        if event.get('workflowId') != workflow_id:
            continue
        ts = parse_ts(event.get('timestamp'))
        if event.get('stepId') == 'fast-downstream' and event.get('status') == 'step_started':
            fast_downstream_started = ts
        if event.get('stepId') == 'slow-branch' and event.get('status') == 'step_finished':
            slow_branch_finished = ts

if fast_downstream_started is None or slow_branch_finished is None:
    raise SystemExit('missing required timing events for streaming assertion')
if not (fast_downstream_started < slow_branch_finished):
    raise SystemExit(
        f'streaming assertion failed: fast-downstream started at {fast_downstream_started.isoformat()} '
        f'but slow-branch finished at {slow_branch_finished.isoformat()}'
    )
PY

  e2e::log "E2E-06 passed"
}

main "$@"
