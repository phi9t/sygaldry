#!/usr/bin/env bash
set -eu -o pipefail

E2E_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly E2E_LIB_DIR
E2E_ROOT_DIR="$(cd "${E2E_LIB_DIR}/../.." && pwd)"
readonly E2E_ROOT_DIR

E2E_ORCH_RETRIES=20
readonly E2E_ORCH_RETRIES
E2E_ORCH_RETRY_SLEEP=2
readonly E2E_ORCH_RETRY_SLEEP


e2e::log() {
  echo "[e2e] $*"
}


e2e::fail() {
  echo "[e2e][error] $*" >&2
  exit 1
}


e2e::require_cmd() {
  local command_name
  command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    e2e::fail "required command not found: ${command_name}"
  fi
}


e2e::check_prereqs() {
  e2e::require_cmd docker
  e2e::require_cmd go
  e2e::require_cmd python3
  e2e::require_cmd rg
}


e2e::new_tmp_dir() {
  mktemp -d "${TMPDIR:-/tmp}/temporal-e2e-XXXXXX"
}


e2e::wait_port() {
  local host
  local port
  local max_tries
  local sleep_secs
  local i

  host="$1"
  port="$2"
  max_tries="$3"
  sleep_secs="$4"

  for ((i = 1; i <= max_tries; i++)); do
    if (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_secs"
  done

  return 1
}


e2e::ensure_temporal() {
  e2e::log "starting Temporal services via docker compose"
  if ! (
    cd "$E2E_ROOT_DIR"
    docker compose up -d >/dev/null
  ); then
    e2e::log "compose up failed, resetting Temporal stack and retrying"
    (
      cd "$E2E_ROOT_DIR"
      docker compose down >/dev/null 2>&1 || true
      docker compose up -d >/dev/null
    )
  fi

  if ! e2e::wait_port 127.0.0.1 7233 90 1; then
    e2e::fail "Temporal did not become ready on 127.0.0.1:7233"
  fi

  if ! e2e::wait_temporal_client_ready 90; then
    e2e::log "Temporal frontend not client-ready; resetting stack and retrying"
    (
      cd "$E2E_ROOT_DIR"
      docker compose down >/dev/null 2>&1 || true
      docker compose up -d >/dev/null
    )
    if ! e2e::wait_port 127.0.0.1 7233 90 1; then
      e2e::fail "Temporal did not become ready on 127.0.0.1:7233 after reset"
    fi
    if ! e2e::wait_temporal_client_ready 120; then
      e2e::fail "Temporal frontend never reached client-ready state"
    fi
  fi
}


e2e::worker_bin() {
  echo "/tmp/temporal-worker-e2e"
}


e2e::build_worker() {
  local worker_bin
  worker_bin="$(e2e::worker_bin)"
  (
    cd "$E2E_ROOT_DIR"
    go build -o "$worker_bin" ./cmd/worker
  )
}


e2e::start_worker() {
  local task_queue
  local log_dir
  local worker_log
  local worker_bin
  local attempt
  local wait_idx

  task_queue="$1"
  log_dir="$2"
  worker_log="$3"
  worker_bin="$(e2e::worker_bin)"

  e2e::build_worker
  for ((attempt = 1; attempt <= 8; attempt++)); do
    : >"$worker_log"
    nohup env TEMPORAL_TASK_QUEUE="$task_queue" TEMPORAL_LOG_DIR="$log_dir" TEMPORAL_LOG_MAX_BYTES=2000 \
      "$worker_bin" >"$worker_log" 2>&1 &
    E2E_WORKER_PID=$!
    export E2E_WORKER_PID

    for ((wait_idx = 1; wait_idx <= 10; wait_idx++)); do
      if rg -q "worker started on task queue" "$worker_log"; then
        return 0
      fi
      if ! kill -0 "$E2E_WORKER_PID" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    kill "$E2E_WORKER_PID" >/dev/null 2>&1 || true
    E2E_WORKER_PID=""
    export E2E_WORKER_PID
    sleep 1
  done

  cat "$worker_log" >&2 || true
  e2e::fail "worker failed to start after retries (see ${worker_log})"
}


e2e::stop_worker() {
  if [[ -n "${E2E_WORKER_PID:-}" ]]; then
    kill "$E2E_WORKER_PID" >/dev/null 2>&1 || true
  fi
}


e2e::orchestrate_once() {
  local out_file
  local err_file
  out_file="$1"
  err_file="$2"
  shift 2

  (
    cd "$E2E_ROOT_DIR"
    GOFLAGS="-mod=mod" go run ./cmd/orchestrate "$@"
  ) >"$out_file" 2>"$err_file"
}


e2e::retry_orchestrate() {
  local out_file
  local err_file
  local attempt

  out_file="$1"
  err_file="$2"
  shift 2

  for ((attempt = 1; attempt <= E2E_ORCH_RETRIES; attempt++)); do
    if e2e::orchestrate_once "$out_file" "$err_file" "$@"; then
      return 0
    fi

    if rg -q "unable to create Temporal client|failed reaching server|connection error|connection reset by peer" "$err_file"; then
      sleep "$E2E_ORCH_RETRY_SLEEP"
      continue
    fi

    return 1
  done

  return 1
}


e2e::wait_temporal_client_ready() {
  local timeout_secs
  local deadline
  local out_file
  local err_file

  timeout_secs="$1"
  deadline=$((SECONDS + timeout_secs))
  out_file="$(mktemp)"
  err_file="$(mktemp)"

  while ((SECONDS < deadline)); do
    if e2e::orchestrate_once "$out_file" "$err_file" status -workflow-id "__e2e_probe__" -output json; then
      rm -f "$out_file" "$err_file"
      return 0
    fi
    if rg -qi "workflow.*not found|not found|unable to describe workflow" "$err_file"; then
      rm -f "$out_file" "$err_file"
      return 0
    fi
    sleep 1
  done

  cat "$err_file" >&2 || true
  rm -f "$out_file" "$err_file"
  return 1
}


e2e::wait_for_terminal_status() {
  local workflow_id
  local timeout_secs
  local output_file
  local status_file
  local err_file
  local status
  local deadline

  workflow_id="$1"
  timeout_secs="$2"
  output_file="$3"

  status_file="$(mktemp)"
  err_file="$(mktemp)"
  deadline=$((SECONDS + timeout_secs))

  while ((SECONDS < deadline)); do
    if e2e::retry_orchestrate "$status_file" "$err_file" status -workflow-id "$workflow_id" -output json; then
      status="$(python3 - "$status_file" <<'PY'
import json
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    raw = f.read()
start = raw.find('{')
if start < 0:
    raise SystemExit('no JSON payload in status output')
payload = json.loads(raw[start:])
print(payload.get('status', ''))
PY
)"
      case "$status" in
        Running|RUNNING|UNSPECIFIED|Unspecified|"")
          sleep 1
          ;;
        *)
          cp "$status_file" "$output_file"
          rm -f "$status_file" "$err_file"
          return 0
          ;;
      esac
      continue
    fi

    if rg -q "not found" "$err_file"; then
      sleep 1
      continue
    fi

    cat "$err_file" >&2
    rm -f "$status_file" "$err_file"
    return 1
  done

  cat "$err_file" >&2 || true
  rm -f "$status_file" "$err_file"
  return 1
}


e2e::assert_contains() {
  local file_path
  local expected
  file_path="$1"
  expected="$2"

  if ! rg -q --fixed-strings "$expected" "$file_path"; then
    e2e::fail "expected '${expected}' in ${file_path}"
  fi
}


e2e::assert_file() {
  local file_path
  file_path="$1"
  if [[ ! -f "$file_path" ]]; then
    e2e::fail "expected file to exist: ${file_path}"
  fi
}
