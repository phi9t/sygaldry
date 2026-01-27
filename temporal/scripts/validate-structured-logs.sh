#!/usr/bin/env bash
set -euo pipefail

LOG_DIR=${LOG_DIR:-${1:-/tmp/temporal-e2e-logs}}

if [[ ! -f "$LOG_DIR/events.jsonl" ]]; then
  echo "events.jsonl not found at $LOG_DIR/events.jsonl" >&2
  exit 1
fi

python3 - <<'PY'
import json
import os
import sys

log_dir = os.environ.get("LOG_DIR", "/tmp/temporal-e2e-logs")
path = os.path.join(log_dir, "events.jsonl")

latest = None
with open(path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        latest = ev

if not latest:
    print("no events found", file=sys.stderr)
    sys.exit(1)

workflow_id = latest.get("workflowId")
run_id = latest.get("runId")
if not workflow_id or not run_id:
    print("workflowId/runId missing in latest event", file=sys.stderr)
    sys.exit(1)

steps = {}
with open(path, "r", encoding="utf-8") as f:
    for line in f:
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("workflowId") != workflow_id or ev.get("runId") != run_id:
            continue
        if ev.get("status") == "step_finished":
            steps[ev.get("stepId")] = ev

if not steps:
    print("no step_finished events for latest run", file=sys.stderr)
    sys.exit(1)

for step, ev in steps.items():
    spath = ev.get("structuredPath")
    if not spath or not os.path.exists(spath):
        print(f"missing structuredPath for {step}: {spath}", file=sys.stderr)
        sys.exit(1)
    with open(spath, "r", encoding="utf-8") as sf:
        first = sf.readline().strip()
    if not first:
        print(f"empty structured log for {step}", file=sys.stderr)
        sys.exit(1)
    try:
        obj = json.loads(first)
    except json.JSONDecodeError as exc:
        print(f"invalid JSON in structured log for {step}: {exc}", file=sys.stderr)
        sys.exit(1)
    for key in ("timestamp", "workflowId", "runId", "stepId", "stream", "message"):
        if key not in obj:
            print(f"structured log missing {key} for {step}", file=sys.stderr)
            sys.exit(1)

print("structured logs ok")
PY
