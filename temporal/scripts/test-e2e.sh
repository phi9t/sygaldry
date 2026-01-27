#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOG_DIR=${TEMPORAL_LOG_DIR:-/tmp/temporal-e2e-logs}
WORKER_LOG=${WORKER_LOG:-/tmp/temporal-e2e-worker.log}
WORKFLOW_ID=${WORKFLOW_ID:-e2e-$(date +%Y%m%d-%H%M%S)}
TASK_QUEUE=${TASK_QUEUE:-e2e-queue-$(date +%s)}

cd "$ROOT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required for this test" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

# Start Temporal (idempotent)
docker compose up -d

# Wait for Temporal port
for i in {1..60}; do
  if (echo > /dev/tcp/127.0.0.1/7233) >/dev/null 2>&1; then
    break
  fi
  sleep 2
  if [[ $i -eq 60 ]]; then
    echo "Temporal did not become ready" >&2
    exit 1
  fi
done

# Start worker (local build for consistent behavior)
go build -o /tmp/temporal-worker ./cmd/worker
nohup env TEMPORAL_TASK_QUEUE="$TASK_QUEUE" TEMPORAL_LOG_DIR="$LOG_DIR" TEMPORAL_LOG_MAX_BYTES=2000 /tmp/temporal-worker > "$WORKER_LOG" 2>&1 &
WORKER_PID=$!

cleanup() {
  kill "$WORKER_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Run workflow
GOFLAGS="-mod=mod" go run ./cmd/orchestrate -workflow-id "$WORKFLOW_ID" -task-queue "$TASK_QUEUE" -plan examples/e2e_test.yaml -log-dir "$LOG_DIR" > /tmp/temporal-e2e.out

LOG_DIR="$LOG_DIR" WORKFLOW_ID="$WORKFLOW_ID" python3 - <<'PY'
import json
import os
import sys

log_dir = os.environ.get("LOG_DIR", "/tmp/temporal-e2e-logs")
workflow_id = os.environ.get("WORKFLOW_ID")

if not workflow_id:
    print("WORKFLOW_ID not set", file=sys.stderr)
    sys.exit(1)

path = os.path.join(log_dir, "events.jsonl")
if not os.path.exists(path):
    print(f"events.jsonl not found at {path}")
    sys.exit(1)

steps = {"step-one": 0, "step-two": 0, "step-three": 0}
with open(path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("workflowId") != workflow_id:
            continue
        step = ev.get("stepId")
        if step in steps and ev.get("status") == "step_finished":
            steps[step] += 1

missing = [k for k, v in steps.items() if v == 0]
if missing:
    print("missing finished events for:", ", ".join(missing))
    sys.exit(1)

print("e2e ok")
PY

# Validate structured logs for the latest run in this log dir
LOG_DIR="$LOG_DIR" ./scripts/validate-structured-logs.sh

# Check for log files
for step in step-one step-two step-three; do
  if ! ls "$LOG_DIR" | rg -q "${WORKFLOW_ID}.*${step}_stdout\.log"; then
    echo "missing stdout log for ${step}" >&2
    exit 1
  fi
  if ! ls "$LOG_DIR" | rg -q "${WORKFLOW_ID}.*${step}_stderr\.log"; then
    echo "missing stderr log for ${step}" >&2
    exit 1
  fi
done

echo "E2E test passed. Logs in $LOG_DIR"
