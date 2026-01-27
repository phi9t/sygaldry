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
  local version
  local workflow_id
  local task_queue

  e2e::check_prereqs
  run_dir="$(e2e::new_tmp_dir)"
  log_dir="${run_dir}/logs"
  worker_log="${run_dir}/worker.log"
  out_json="${run_dir}/run.json"
  err_log="${run_dir}/orchestrate.err"
  version="v$(date +%s)-$$"
  task_queue="e2e02-queue-$(date +%s)-$$"

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

  workflow_id="e2e02-$(date +%Y%m%d-%H%M%S)-$$"
  if ! e2e::retry_orchestrate "${out_json}" "${err_log}" run -workflow-id "${workflow_id}" -task-queue "${task_queue}" -plan examples/e2e/params_outputs.yaml -set "version=${version}" -log-dir "${log_dir}" -output json; then
    cat "${err_log}" >&2
    e2e::fail "params/outputs run failed"
  fi

  python3 - "${out_json}" "${version}" <<'PY'
import json
import sys

path = sys.argv[1]
version = sys.argv[2]
expected = f"my-org/my-image:{version}"

with open(path, 'r', encoding='utf-8') as f:
    raw = f.read()
start = raw.find('{')
if start < 0:
    raise SystemExit('missing JSON payload')
payload = json.loads(raw[start:])

result = payload.get('result', {})
steps = {step.get('id'): step for step in result.get('steps', [])}
produce = steps.get('produce')
consume = steps.get('consume')
if not produce or not consume:
    raise SystemExit('missing produce/consume steps in result')

outputs = produce.get('result', {}).get('outputs', {})
if outputs.get('image_tag') != expected:
    raise SystemExit(f"unexpected output image_tag: {outputs.get('image_tag')} != {expected}")

stdout = consume.get('result', {}).get('stdout', '')
if f"resolved={expected}" not in stdout:
    raise SystemExit(f"consume stdout missing resolved tag: {stdout!r}")

if consume.get('state') != 'success':
    raise SystemExit(f"consume state not success: {consume.get('state')}")
PY

  e2e::log "E2E-02 passed"
}

main "$@"
