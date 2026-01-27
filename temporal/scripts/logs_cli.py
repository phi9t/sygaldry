#!/usr/bin/env python3
import argparse
import json
import os
import sys
from collections import defaultdict
from time import sleep


def read_events(path):
    if not os.path.exists(path):
        return []
    events = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def list_runs(events):
    runs = {}
    for ev in events:
        key = (ev.get("workflowId"), ev.get("runId"))
        if not key[0] or not key[1]:
            continue
        ts = ev.get("timestamp")
        runs.setdefault(key, {"workflowId": key[0], "runId": key[1], "last": ts})
        if ts and (runs[key]["last"] is None or ts > runs[key]["last"]):
            runs[key]["last"] = ts
    for run in sorted(runs.values(), key=lambda r: r.get("last") or "", reverse=True):
        print(f"{run['workflowId']}\t{run['runId']}\t{run.get('last','')}")


def show_steps(events, workflow_id, run_id):
    steps = defaultdict(lambda: {"status": None, "exitCode": None, "durationSec": None})
    for ev in events:
        if ev.get("workflowId") != workflow_id or ev.get("runId") != run_id:
            continue
        step = ev.get("stepId") or ev.get("stepName") or "unknown"
        if ev.get("status") == "step_finished":
            steps[step] = {
                "status": "finished",
                "exitCode": ev.get("exitCode"),
                "durationSec": ev.get("durationSec"),
                "stdoutPath": ev.get("stdoutPath"),
                "stderrPath": ev.get("stderrPath"),
                "structuredPath": ev.get("structuredPath"),
            }
        elif ev.get("status") == "step_started":
            if steps[step]["status"] is None:
                steps[step]["status"] = "started"
    for step_id, info in steps.items():
        print(
            f"{step_id}\t{info.get('status')}\t{info.get('exitCode')}\t{info.get('durationSec')}\t{info.get('stdoutPath','')}\t{info.get('stderrPath','')}\t{info.get('structuredPath','')}"
        )


def tail(events_path, workflow_id, run_id):
    events = read_events(events_path)
    for ev in events:
        if ev.get("workflowId") != workflow_id or ev.get("runId") != run_id:
            continue
        print(json.dumps(ev))


def follow(events_path, workflow_id, run_id):
    if not os.path.exists(events_path):
        print(f"events file not found: {events_path}", file=sys.stderr)
        return
    with open(events_path, "r", encoding="utf-8") as f:
        f.seek(0, os.SEEK_END)
        while True:
            line = f.readline()
            if not line:
                sleep(0.5)
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("workflowId") != workflow_id or ev.get("runId") != run_id:
                continue
            print(json.dumps(ev), flush=True)


def main():
    parser = argparse.ArgumentParser(description="Inspect Temporal step events")
    parser.add_argument(
        "--log-dir", default="logs", help="log directory (default: logs)"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list-runs")

    show = sub.add_parser("show-steps")
    show.add_argument("--workflow-id", required=True)
    show.add_argument("--run-id", required=True)

    tail_cmd = sub.add_parser("tail")
    tail_cmd.add_argument("--workflow-id", required=True)
    tail_cmd.add_argument("--run-id", required=True)

    follow_cmd = sub.add_parser("follow")
    follow_cmd.add_argument("--workflow-id", required=True)
    follow_cmd.add_argument("--run-id", required=True)

    args = parser.parse_args()
    events_path = os.path.join(args.log_dir, "events.jsonl")

    events = read_events(events_path)
    if args.command == "list-runs":
        list_runs(events)
    elif args.command == "show-steps":
        show_steps(events, args.workflow_id, args.run_id)
    elif args.command == "tail":
        tail(events_path, args.workflow_id, args.run_id)
    elif args.command == "follow":
        follow(events_path, args.workflow_id, args.run_id)


if __name__ == "__main__":
    main()
