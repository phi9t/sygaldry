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
  local summary_out
  local steps_out
  local dag_out
  local api_runs
  local api_run
  local api_dag
  local viz_log
  local workflow_id
  local run_id
  local task_queue
  local viz_port

  e2e::check_prereqs
  e2e::require_cmd curl
  e2e::require_cmd node

  run_dir="$(e2e::new_tmp_dir)"
  log_dir="${run_dir}/logs"
  worker_log="${run_dir}/worker.log"
  run_json="${run_dir}/run.json"
  run_err="${run_dir}/run.err"
  summary_out="${run_dir}/summary.out"
  steps_out="${run_dir}/steps.out"
  dag_out="${run_dir}/dag.out"
  api_runs="${run_dir}/api_runs.json"
  api_run="${run_dir}/api_run.json"
  api_dag="${run_dir}/api_dag.json"
  viz_log="${run_dir}/visualizer.log"
  task_queue="e2e07-queue-$(date +%s)-$$"
  viz_port="18787"

  cleanup() {
    if [[ -n "${E2E_VIZ_PID:-}" ]]; then
      kill "${E2E_VIZ_PID}" >/dev/null 2>&1 || true
    fi
    e2e::stop_worker
    if [[ -n "${run_dir:-}" ]]; then
      rm -rf "${run_dir}"
    fi
  }
  trap cleanup EXIT

  mkdir -p "${log_dir}"
  e2e::ensure_temporal
  e2e::start_worker "${task_queue}" "${log_dir}" "${worker_log}"

  TEMPORAL_LOG_DIR="${log_dir}" PORT="${viz_port}" node "${E2E_ROOT_DIR}/visualizer/server.js" >"${viz_log}" 2>&1 &
  E2E_VIZ_PID=$!
  export E2E_VIZ_PID

  if ! e2e::wait_port 127.0.0.1 "${viz_port}" 60 1; then
    if [[ -f "${viz_log}" ]]; then
      cat "${viz_log}" >&2 || true
    fi
    e2e::fail "visualizer did not start on port ${viz_port}"
  fi

  workflow_id="e2e07-$(date +%Y%m%d-%H%M%S)-$$"
  if ! e2e::retry_orchestrate "${run_json}" "${run_err}" run -workflow-id "${workflow_id}" -task-queue "${task_queue}" -plan examples/e2e/monitoring_consistency.yaml -log-dir "${log_dir}" -output json; then
    cat "${run_err}" >&2
    e2e::fail "monitoring consistency scenario failed"
  fi

run_id="$(python3 - "${run_json}" <<'PY'
import json
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    raw = f.read()
start = raw.find('{')
if start < 0:
    raise SystemExit('missing JSON payload')
payload = json.loads(raw[start:])
run_id = payload.get('runId')
if not run_id:
    raise SystemExit('missing runId')
print(run_id)
PY
)"

  (
    cd "${E2E_ROOT_DIR}"
    ./scripts/logs_cli.py --log-dir "${log_dir}" summary --workflow-id "${workflow_id}" --run-id "${run_id}" >"${summary_out}"
    ./scripts/logs_cli.py --log-dir "${log_dir}" show-steps --workflow-id "${workflow_id}" --run-id "${run_id}" >"${steps_out}"
    ./scripts/logs_cli.py --log-dir "${log_dir}" dag --workflow-id "${workflow_id}" --run-id "${run_id}" >"${dag_out}"
  )

  curl -fsS "http://127.0.0.1:${viz_port}/api/runs" >"${api_runs}"
  curl -fsS "http://127.0.0.1:${viz_port}/api/runs/${run_id}" >"${api_run}"
  curl -fsS "http://127.0.0.1:${viz_port}/api/dag?runId=${run_id}" >"${api_dag}"

  python3 - "${log_dir}" "${workflow_id}" "${run_id}" "${steps_out}" "${api_runs}" "${api_run}" "${api_dag}" <<'PY'
import json
import os
import sys

log_dir = sys.argv[1]
workflow_id = sys.argv[2]
run_id = sys.argv[3]
steps_out_path = sys.argv[4]
api_runs_path = sys.argv[5]
api_run_path = sys.argv[6]
api_dag_path = sys.argv[7]

manifest_path = os.path.join(log_dir, f"{workflow_id.replace('/', '_')}_{run_id.replace('/', '_')}_plan.json")
if not os.path.exists(manifest_path):
    raise SystemExit(f"missing manifest file: {manifest_path}")

with open(manifest_path, 'r', encoding='utf-8') as f:
    manifest = json.load(f)
manifest_ids = [step['id'] for step in manifest.get('steps', [])]

with open(api_runs_path, 'r', encoding='utf-8') as f:
    runs = json.load(f)
if not any(r.get('workflowId') == workflow_id and r.get('runId') == run_id for r in runs):
    raise SystemExit('run not found in /api/runs output')

with open(api_run_path, 'r', encoding='utf-8') as f:
    run = json.load(f)
api_run_ids = sorted(step.get('stepId') for step in run.get('steps', []))
if sorted(manifest_ids) != api_run_ids:
    raise SystemExit(f"step mismatch manifest vs /api/runs/:id: {manifest_ids} vs {api_run_ids}")

with open(api_dag_path, 'r', encoding='utf-8') as f:
    dag = json.load(f)
dag_ids = sorted(node.get('id') for node in dag.get('nodes', []))
if sorted(manifest_ids) != dag_ids:
    raise SystemExit(f"step mismatch manifest vs /api/dag nodes: {manifest_ids} vs {dag_ids}")

with open(steps_out_path, 'r', encoding='utf-8') as f:
    cli_step_lines = [line.strip() for line in f if line.strip()]
if len(cli_step_lines) != len(manifest_ids):
    raise SystemExit(f"logs_cli show-steps line count mismatch: {len(cli_step_lines)} vs {len(manifest_ids)}")
PY

  e2e::assert_contains "${summary_out}" "Pipeline: ${workflow_id}"
  e2e::assert_contains "${dag_out}" "DAG:"

  e2e::log "E2E-07 passed"
}

main "$@"
