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
  local validate_out
  local validate_err
  local workflow_id
  local task_queue

  e2e::check_prereqs
  run_dir="$(e2e::new_tmp_dir)"
  log_dir="${run_dir}/logs"
  worker_log="${run_dir}/worker.log"
  run_json="${run_dir}/run.json"
  run_err="${run_dir}/run.err"
  validate_out="${run_dir}/validate.out"
  validate_err="${run_dir}/validate.err"
  task_queue="e2e03-queue-$(date +%s)-$$"

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

  workflow_id="e2e03-$(date +%Y%m%d-%H%M%S)-$$"
  if ! e2e::retry_orchestrate "${run_json}" "${run_err}" run -workflow-id "${workflow_id}" -task-queue "${task_queue}" -plan examples/e2e/templates_valid.yaml -log-dir "${log_dir}" -output json; then
    cat "${run_err}" >&2
    e2e::fail "template run failed"
  fi

  python3 - "${run_json}" <<'PY'
import json
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    raw = f.read()
start = raw.find('{')
if start < 0:
    raise SystemExit('missing JSON payload')
payload = json.loads(raw[start:])
steps = {step.get('id'): step for step in payload.get('result', {}).get('steps', [])}
merge_step = steps.get('merge-check')
helper_step = steps.get('helper-check')
if not merge_step or not helper_step:
    raise SystemExit('missing expected template steps')
merge_stdout = merge_step.get('result', {}).get('stdout', '')
if 'base:step:override' not in merge_stdout:
    raise SystemExit(f'unexpected merge stdout: {merge_stdout!r}')
helper_stdout = helper_step.get('result', {}).get('stdout', '')
if 'helper-ok' not in helper_stdout:
    raise SystemExit(f'unexpected helper stdout: {helper_stdout!r}')
PY

  if (
    cd "${E2E_ROOT_DIR}"
    GOFLAGS="-mod=mod" go run ./cmd/orchestrate validate -plan examples/e2e/templates_duplicate.yaml
  ) >"${validate_out}" 2>"${validate_err}"; then
    e2e::fail "duplicate template import should fail validation"
  fi

  e2e::assert_contains "${validate_err}" "duplicate template name"
  e2e::log "E2E-03 passed"
}

main "$@"
